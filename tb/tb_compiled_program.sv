`timescale 1ns/1ps

module tb_compiled_program;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 8;
`ifdef FPGA_ENGINE
    localparam integer ADDR_W = 7;
    localparam integer MAX_EXECUTION_CYCLES = 10000;
`else
    localparam integer ADDR_W = 8;
    localparam integer MAX_EXECUTION_CYCLES = 10000;
`endif
    localparam integer IMEM_DEPTH = 16;
    localparam integer M = 6;
    localparam integer K = 10;
    localparam integer N = 10;
    localparam integer PROGRAM_WORDS = 5;

    logic clk;
    logic rst_n;
    logic program_we;
    logic [$clog2(IMEM_DEPTH)-1:0] program_addr;
    logic [127:0] program_wdata;
    logic dma_valid;
    logic dma_ready;
    logic dma_write;
    logic [1:0] dma_mem;
    logic [ADDR_W-1:0] dma_addr;
    logic [31:0] dma_wdata;
    logic [31:0] dma_rdata;
    logic start;
    logic busy;
    logic done;
    logic fault;
    logic [3:0] fault_code;
    logic [$clog2(IMEM_DEPTH)-1:0] pc_debug;

    logic [127:0] program_image [0:PROGRAM_WORDS-1];
    logic [7:0] a_image [0:M*K-1];
    logic [7:0] b_image [0:K*N-1];
    logic [31:0] expected_image [0:M*N-1];
    integer errors;
    integer cycles;
    integer address;
    integer signed actual;
    integer signed expected;
    integer read_timeout;

`ifdef FPGA_ENGINE
    systolicforge_fpga_engine #(
`else
    systolicforge_npu #(
`endif
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .program_we(program_we),
        .program_addr(program_addr),
        .program_wdata(program_wdata),
        .dma_valid(dma_valid),
        .dma_ready(dma_ready),
        .dma_write(dma_write),
        .dma_mem(dma_mem),
        .dma_addr(dma_addr),
        .dma_wdata(dma_wdata),
        .dma_rdata(dma_rdata),
        .start(start),
        .busy(busy),
        .done(done),
        .fault(fault),
        .fault_code(fault_code),
        .pc_debug(pc_debug)
    );

    always #5 clk = ~clk;

    task automatic write_program(input integer target, input [127:0] data);
        begin
            @(negedge clk);
            program_we = 1'b1;
            program_addr = target;
            program_wdata = data;
            @(negedge clk);
            program_we = 1'b0;
        end
    endtask

    task automatic write_data(
        input logic [1:0] memory,
        input integer target,
        input [31:0] data
    );
        begin
            @(negedge clk);
            dma_valid = 1'b1;
            dma_write = 1'b1;
            dma_mem = memory;
            dma_addr = target;
            dma_wdata = data;
            @(negedge clk);
            dma_valid = 1'b0;
            dma_write = 1'b0;
        end
    endtask

    initial begin
        $readmemh("build/example_program/program.hex", program_image);
        $readmemh("build/example_program/a.hex", a_image);
        $readmemh("build/example_program/b.hex", b_image);
        $readmemh("build/example_program/c_expected.hex", expected_image);

        clk = 1'b0;
        rst_n = 1'b0;
        program_we = 1'b0;
        program_addr = '0;
        program_wdata = '0;
        dma_valid = 1'b0;
        dma_write = 1'b0;
        dma_mem = '0;
        dma_addr = '0;
        dma_wdata = '0;
        start = 1'b0;
        errors = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (address = 0; address < M*K; address = address + 1)
            write_data(2'd0, address, {24'd0, a_image[address]});
        for (address = 0; address < K*N; address = address + 1)
            write_data(2'd1, address, {24'd0, b_image[address]});
        for (address = 0; address < PROGRAM_WORDS; address = address + 1)
            write_program(address, program_image[address]);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (!done && cycles < MAX_EXECUTION_CYCLES) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("ERROR: compiled program timed out at PC=%0d", pc_debug);
            errors = errors + 1;
        end
        if (fault) begin
            $display("ERROR: compiled program faulted with code 0x%0h at PC=%0d",
                     fault_code, pc_debug);
            errors = errors + 1;
        end
        if (fault_code != 0) begin
            $display("ERROR: compiled program retained fault code 0x%0h",
                     fault_code);
            errors = errors + 1;
        end

        for (address = 0; address < M*N; address = address + 1) begin
            @(negedge clk);
            dma_valid = 1'b1;
            dma_write = 1'b0;
            dma_mem = 2'd2;
            dma_addr = address;
            #1;
            read_timeout = 0;
            while (!dma_ready && read_timeout < 20) begin
                @(negedge clk);
                read_timeout = read_timeout + 1;
            end
            if (!dma_ready) $fatal(1, "compiled result read timed out");
            actual = $signed(dma_rdata);
            expected = $signed(expected_image[address]);
            if (actual !== expected) begin
                $display(
                    "ERROR: compiled C[%0d] expected %0d, got %0d",
                    address, expected, actual
                );
                errors = errors + 1;
            end
            @(negedge clk);
            dma_valid = 1'b0;
        end

        if (errors == 0)
            $display(
                "PASS: compiler-generated %0d-word program produced all %0d golden outputs",
                PROGRAM_WORDS, M*N
            );
        else
            $fatal(1, "FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
