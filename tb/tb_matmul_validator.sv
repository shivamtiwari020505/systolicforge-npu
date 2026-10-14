`timescale 1ns/1ps

module tb_matmul_validator;
    logic clk = 0, rst_n = 0, request = 0, pc_at_last = 0;
    logic [127:0] instruction = 0;
    wire valid;
    wire [3:0] fault_code;
    integer sent = 0, received = 0, seed = 32'h71a2026;
    integer expected [0:511];
    integer i;
    logic [127:0] candidate;
    always #5 clk = ~clk;
    systolicforge_matmul_validator dut (.*);

    function automatic integer golden(input logic [127:0] word,
                                       input logic last_pc);
        longint unsigned m, k, n, a_end, b_end, c_end;
        begin
            m = 64'(word[15:8]); k = 64'(word[23:16]); n = 64'(word[31:24]);
            a_end = 64'(word[47:32]) + (m-1)*64'(word[95:80]) + k-1;
            b_end = 64'(word[63:48]) + (k-1)*64'(word[111:96]) + n-1;
            c_end = 64'(word[79:64]) + (m-1)*64'(word[127:112]) + n-1;
            if (m == 0 || k == 0 || n == 0 || k > 8 || n > 8) golden = 2;
            else if (last_pc) golden = 4;
            else if (a_end >= 4096 || b_end >= 4096 || c_end >= 4096) golden = 3;
            else golden = 0;
        end
    endfunction

    task automatic send(input logic [127:0] word, input logic last_pc);
        @(negedge clk);
        request = 1; instruction = word; pc_at_last = last_pc;
        expected[sent] = golden(word, last_pc); sent = sent + 1;
    endtask

    always @(negedge clk) begin
        if (rst_n && valid) begin
            if (received >= sent || fault_code !== 4'(expected[received]))
                $fatal(1, "validator response %0d expected=%0d actual=%0d",
                       received, expected[received], fault_code);
            received = received + 1;
        end
    end

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        // Exact last address, one-past, huge strides, zero stride, fault priority.
        candidate = 0; candidate[3:0] = 1;
        candidate[31:8] = 24'h010101;
        candidate[79:32] = 48'h0fff0fff0fff;
        send(candidate, 0);
        candidate[47:32] = 4096; send(candidate, 0);
        candidate[47:32] = 4095; candidate[15:8] = 2;
        candidate[95:80] = 1; send(candidate, 0);
        candidate[95:80] = 0; send(candidate, 0);
        candidate[127:80] = 48'hffffffffffff;
        candidate[15:8] = 255; send(candidate, 0);
        send(candidate, 1); // PC fault precedes address fault.
        candidate[15:8] = 0; send(candidate, 1); // Dimension precedes PC.
        // Back-to-back requests prove that early fault and data tags align.
        for (i = 0; i < 256; i = i + 1) begin
            candidate[15:8] = 8'(($random(seed) & 255) + 1);
            candidate[23:16] = 8'(($random(seed) & 7) + 1);
            candidate[31:24] = 8'(($random(seed) & 7) + 1);
            candidate[79:32] = {$random(seed), 16'($random(seed))};
            candidate[127:80] = {$random(seed), 16'($random(seed))};
            if (i % 2 == 0) begin
                candidate[79:32] = 0;
                candidate[127:80] = 48'h000800080008;
            end
            send(candidate, i % 17 == 0);
        end
        @(negedge clk); request = 0;
        repeat (6) @(negedge clk);
        if (received != sent) $fatal(1, "missing validator responses");
        // Cancel a request while it is still inside the pipeline.
        request = 1;
        @(negedge clk); rst_n = 0; request = 0;
        repeat (2) @(negedge clk);
        if (valid) $fatal(1, "reset did not flush validation");
        rst_n = 1;
        repeat (6) @(negedge clk);
        if (valid) $fatal(1, "stale response after validation reset");
        $display("PASS: %0d staged validation cases, fault priority and reset cancellation", received);
        $finish;
    end
endmodule
