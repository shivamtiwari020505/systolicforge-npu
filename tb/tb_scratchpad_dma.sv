`timescale 1ns/1ps

module tb_scratchpad_dma;

    logic clk;
    logic rst_n;
    logic cmd_valid;
    logic cmd_ready;
    logic cmd_to_local;
    logic [1:0] cmd_mem;
    logic [7:0] cmd_local_addr;
    logic [15:0] cmd_ext_addr;
    logic [15:0] cmd_length;
    logic busy;
    logic done;
    logic local_valid;
    logic local_ready;
    logic local_write;
    logic [1:0] local_mem;
    logic [7:0] local_addr;
    logic [31:0] local_wdata;
    logic [31:0] local_rdata;
    logic ext_req_valid;
    logic ext_req_ready;
    logic ext_req_write;
    logic [15:0] ext_req_addr;
    logic [31:0] ext_req_wdata;
    logic ext_rsp_valid;
    logic [31:0] ext_rsp_rdata;

    logic [31:0] local_memory [0:255];
    logic [31:0] external_memory [0:255];
    logic pending_read;
    logic [15:0] pending_addr;
    integer i;
    integer errors;
    integer timeout;

    scratchpad_dma #(
        .LOCAL_ADDR_W(8),
        .EXT_ADDR_W(16),
        .DATA_W(32),
        .LEN_W(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_to_local(cmd_to_local),
        .cmd_mem(cmd_mem),
        .cmd_local_addr(cmd_local_addr),
        .cmd_ext_addr(cmd_ext_addr),
        .cmd_length(cmd_length),
        .busy(busy),
        .done(done),
        .local_valid(local_valid),
        .local_ready(local_ready),
        .local_write(local_write),
        .local_mem(local_mem),
        .local_addr(local_addr),
        .local_wdata(local_wdata),
        .local_rdata(local_rdata),
        .ext_req_valid(ext_req_valid),
        .ext_req_ready(ext_req_ready),
        .ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),
        .ext_req_wdata(ext_req_wdata),
        .ext_rsp_valid(ext_rsp_valid),
        .ext_rsp_rdata(ext_rsp_rdata)
    );

    always #5 clk = ~clk;
    assign local_ready = 1'b1;
    assign local_rdata = local_memory[local_addr];
    assign ext_req_ready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_read <= 1'b0;
            pending_addr <= '0;
            ext_rsp_valid <= 1'b0;
            ext_rsp_rdata <= '0;
        end else begin
            ext_rsp_valid <= pending_read;
            if (pending_read)
                ext_rsp_rdata <= external_memory[pending_addr >> 2];
            pending_read <= ext_req_valid && ext_req_ready && !ext_req_write;
            if (ext_req_valid && ext_req_ready && !ext_req_write)
                pending_addr <= ext_req_addr;
            if (ext_req_valid && ext_req_ready && ext_req_write)
                external_memory[ext_req_addr >> 2] <= ext_req_wdata;
            if (local_valid && local_ready && local_write)
                local_memory[local_addr] <= local_wdata;
        end
    end

    task automatic issue_command(
        input logic to_local,
        input integer local_base,
        input integer ext_base,
        input integer length
    );
        begin
            @(negedge clk);
            cmd_valid      = 1'b1;
            cmd_to_local   = to_local;
            cmd_mem        = 2'd0;
            cmd_local_addr = local_base;
            cmd_ext_addr   = ext_base;
            cmd_length     = length;
            @(negedge clk);
            cmd_valid      = 1'b0;
            timeout = 0;
            while (!done && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done) begin
                $display("ERROR: DMA command timed out");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd_to_local = 1'b0;
        cmd_mem = '0;
        cmd_local_addr = '0;
        cmd_ext_addr = '0;
        cmd_length = '0;
        errors = 0;

        for (i = 0; i < 256; i = i + 1) begin
            local_memory[i] = '0;
            external_memory[i] = 32'h1000_0000 + i;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        issue_command(1'b1, 10, 32, 5);
        for (i = 0; i < 5; i = i + 1) begin
            if (local_memory[10+i] !== 32'h1000_0000 + 8 + i) begin
                $display("ERROR: DMA load word %0d mismatch", i);
                errors = errors + 1;
            end
            local_memory[10+i] = 32'hcafe_0000 + i;
        end

        issue_command(1'b0, 10, 64, 5);
        for (i = 0; i < 5; i = i + 1) begin
            if (external_memory[16+i] !== 32'hcafe_0000 + i) begin
                $display("ERROR: DMA store word %0d mismatch", i);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: DMA moved five-word bursts in both directions");
        else
            $display("FAIL: %0d error(s)", errors);
        $finish(errors != 0);
    end

endmodule
