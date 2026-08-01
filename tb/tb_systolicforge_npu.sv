`timescale 1ns/1ps

module tb_systolicforge_npu;

    localparam integer ARRAY_ROWS = 4;
    localparam integer ARRAY_COLS = 4;
    localparam integer DATA_W     = 8;
    localparam integer ACC_W      = 32;
    localparam integer ADDR_W     = 8;
    localparam integer IMEM_DEPTH = 16;
    localparam integer M = 3;
    localparam integer K = 6;
    localparam integer N = 3;

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
    logic [ACC_W-1:0] dma_wdata;
    logic [ACC_W-1:0] dma_rdata;
    logic start;
    logic busy;
    logic done;
    logic fault;
    logic [$clog2(IMEM_DEPTH)-1:0] pc_debug;

    integer signed a [0:M-1][0:K-1];
    integer signed b [0:K-1][0:N-1];
    integer signed expected [0:M-1][0:N-1];
    integer signed actual;
    integer errors;
    integer i;
    integer j;
    integer k;
    integer cycles;

    systolicforge_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
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
        .pc_debug(pc_debug)
    );

    always #5 clk = ~clk;

    function automatic [127:0] matmul_instruction(
        input integer flags,
        input integer m_size,
        input integer k_size,
        input integer n_size,
        input integer a_base,
        input integer b_base,
        input integer c_base,
        input integer lda,
        input integer ldb,
        input integer ldc
    );
        reg [127:0] inst;
        begin
            inst = '0;
            inst[3:0]    = 4'h1;
            inst[7:4]    = flags[3:0];
            inst[15:8]   = m_size[7:0];
            inst[23:16]  = k_size[7:0];
            inst[31:24]  = n_size[7:0];
            inst[47:32]  = a_base[15:0];
            inst[63:48]  = b_base[15:0];
            inst[79:64]  = c_base[15:0];
            inst[95:80]  = lda[15:0];
            inst[111:96] = ldb[15:0];
            inst[127:112]= ldc[15:0];
            matmul_instruction = inst;
        end
    endfunction

    task automatic write_program(input integer address, input [127:0] data);
        begin
            @(negedge clk);
            program_we    = 1'b1;
            program_addr  = address;
            program_wdata = data;
            @(negedge clk);
            program_we    = 1'b0;
        end
    endtask

    task automatic write_scratchpad(
        input [1:0] memory,
        input integer address,
        input integer signed data
    );
        begin
            @(negedge clk);
            dma_valid = 1'b1;
            dma_write = 1'b1;
            dma_mem   = memory;
            dma_addr  = address;
            dma_wdata = data;
            @(negedge clk);
            dma_valid = 1'b0;
            dma_write = 1'b0;
        end
    endtask

    task automatic read_c(input integer address, output integer signed data);
        begin
            @(negedge clk);
            dma_mem  = 2'd2;
            dma_addr = address;
            #1;
            data = $signed(dma_rdata);
        end
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        program_we    = 1'b0;
        program_addr  = '0;
        program_wdata = '0;
        dma_valid     = 1'b0;
        dma_write     = 1'b0;
        dma_mem       = '0;
        dma_addr      = '0;
        dma_wdata     = '0;
        start         = 1'b0;
        errors        = 0;

        for (i = 0; i < M; i = i + 1)
            for (k = 0; k < K; k = k + 1)
                a[i][k] = ((i * 13 + k * 7) % 23) - 11;

        for (k = 0; k < K; k = k + 1)
            for (j = 0; j < N; j = j + 1)
                b[k][j] = ((k * 9 + j * 5) % 21) - 10;

        for (i = 0; i < M; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                expected[i][j] = 0;
                for (k = 0; k < K; k = k + 1)
                    expected[i][j] = expected[i][j] + a[i][k] * b[k][j];
            end
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (i = 0; i < M; i = i + 1)
            for (k = 0; k < K; k = k + 1)
                write_scratchpad(2'd0, i*K+k, a[i][k]);

        for (k = 0; k < K; k = k + 1)
            for (j = 0; j < N; j = j + 1)
                write_scratchpad(2'd1, k*N+j, b[k][j]);

        // K=6 is split into a 4-row tile and a 2-row accumulation tile.
        write_program(0, matmul_instruction(0, M, 4, N, 0, 0, 0, K, N, N));
        write_program(1, matmul_instruction(1, M, 2, N, 4, 4*N, 0, K, N, N));
        write_program(2, 128'hf);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        cycles = 0;
        while (!done && cycles < 200) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        if (!done) begin
            $display("ERROR: NPU timed out at PC=%0d", pc_debug);
            errors = errors + 1;
        end
        if (fault) begin
            $display("ERROR: NPU raised fault at PC=%0d", pc_debug);
            errors = errors + 1;
        end

        for (i = 0; i < M; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                read_c(i*N+j, actual);
                if (actual !== expected[i][j]) begin
                    $display(
                        "ERROR: C[%0d][%0d] expected %0d, got %0d",
                        i, j, expected[i][j], actual
                    );
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("PASS: mini-NPU executed two tiled MATMUL instructions in %0d cycles", cycles);
        else
            $display("FAIL: %0d error(s)", errors);

        $finish(errors != 0);
    end

endmodule
