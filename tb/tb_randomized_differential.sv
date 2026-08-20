`timescale 1ns/1ps

module tb_randomized_differential;

    localparam integer ARRAY_ROWS = 4;
    localparam integer ARRAY_COLS = 4;
    localparam integer ADDR_W = 8;
    localparam integer SCRATCHPAD_WORDS = 1 << ADDR_W;
    localparam integer IMEM_DEPTH = 32;
    localparam integer EXT_ADDR_W = 32;
    localparam integer EXT_WORDS = 2048;
    localparam integer EXT_WORD_ADDR_W = $clog2(EXT_WORDS);

    localparam integer EXT_A_BASE = 32'h0000_0100;
    localparam integer EXT_B_BASE = 32'h0000_0800;
    localparam integer EXT_C_BASE = 32'h0000_1000;

    localparam integer CFG_SEED = 0;
    localparam integer CFG_CASE_INDEX = 1;
    localparam integer CFG_M = 2;
    localparam integer CFG_K = 3;
    localparam integer CFG_N = 4;
    localparam integer CFG_LDA = 5;
    localparam integer CFG_LDB = 6;
    localparam integer CFG_LDC = 7;
    localparam integer CFG_PROGRAM_WORDS = 8;
    localparam integer CFG_A_BASE = 9;
    localparam integer CFG_A_WORDS = 10;
    localparam integer CFG_B_BASE = 11;
    localparam integer CFG_B_WORDS = 12;
    localparam integer CFG_C_BASE = 13;
    localparam integer CFG_C_WORDS = 14;
    localparam integer CFG_STALL_SEED = 15;

    localparam logic [1:0] MEM_A = 2'd0;
    localparam logic [1:0] MEM_B = 2'd1;
    localparam logic [1:0] MEM_C = 2'd2;

    logic clk;
    logic rst_n;

    logic program_we;
    logic [$clog2(IMEM_DEPTH)-1:0] program_addr;
    logic [127:0] program_wdata;

    logic start;
    logic busy;
    logic done;
    logic fault;
    logic [3:0] fault_code;

    logic dma_cmd_valid;
    logic dma_cmd_ready;
    logic dma_cmd_to_local;
    logic [1:0] dma_cmd_mem;
    logic [ADDR_W-1:0] dma_cmd_local_addr;
    logic [EXT_ADDR_W-1:0] dma_cmd_ext_addr;
    logic [15:0] dma_cmd_length;
    logic dma_busy;
    logic dma_done;

    logic ext_req_valid;
    logic ext_req_ready;
    logic ext_req_write;
    logic [EXT_ADDR_W-1:0] ext_req_addr;
    logic [31:0] ext_req_wdata;
    logic ext_rsp_valid;
    logic [31:0] ext_rsp_rdata;

    logic [31:0] config_image [0:CFG_STALL_SEED];
    logic [127:0] program_image [0:IMEM_DEPTH-1];
    logic [31:0] a_image [0:SCRATCHPAD_WORDS-1];
    logic [31:0] b_image [0:SCRATCHPAD_WORDS-1];
    logic [31:0] c_initial_image [0:SCRATCHPAD_WORDS-1];
    logic [31:0] c_expected_image [0:SCRATCHPAD_WORDS-1];
    logic [31:0] external_memory [0:EXT_WORDS-1];

    logic pending_read;
    logic [EXT_ADDR_W-1:0] pending_read_addr;
    logic [2:0] read_delay;
    logic [31:0] stall_lfsr;
    logic read_stall_forced;
    logic write_stall_forced;
    wire force_first_stall = ext_req_valid &&
        ((!ext_req_write && !read_stall_forced) ||
         (ext_req_write && !write_stall_forced));

    integer memory_cycle;
    integer read_requests;
    integer write_requests;
    integer read_request_stalls;
    integer write_request_stalls;
    integer protocol_errors;

    integer seed;
    integer case_index;
    integer m_size;
    integer k_size;
    integer n_size;
    integer lda;
    integer ldb;
    integer ldc;
    integer program_words;
    integer a_base;
    integer a_words;
    integer b_base;
    integer b_words;
    integer c_base;
    integer c_words;
    logic [31:0] stall_seed;

    integer address;
    integer errors;
    integer timeout;
    integer compute_cycles;
    logic [31:0] actual_word;
    logic [31:0] expected_word;

    systolicforge_soc #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH),
        .EXT_ADDR_W(EXT_ADDR_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .program_we(program_we),
        .program_addr(program_addr),
        .program_wdata(program_wdata),
        .start(start),
        .busy(busy),
        .done(done),
        .fault(fault),
        .fault_code(fault_code),
        .dma_cmd_valid(dma_cmd_valid),
        .dma_cmd_ready(dma_cmd_ready),
        .dma_cmd_to_local(dma_cmd_to_local),
        .dma_cmd_mem(dma_cmd_mem),
        .dma_cmd_local_addr(dma_cmd_local_addr),
        .dma_cmd_ext_addr(dma_cmd_ext_addr),
        .dma_cmd_length(dma_cmd_length),
        .dma_busy(dma_busy),
        .dma_done(dma_done),
        .ext_req_valid(ext_req_valid),
        .ext_req_ready(ext_req_ready),
        .ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),
        .ext_req_wdata(ext_req_wdata),
        .ext_rsp_valid(ext_rsp_valid),
        .ext_rsp_rdata(ext_rsp_rdata)
    );

    always #5 clk = ~clk;

    // Every case forces the first read and write request to stall. Later
    // requests use a case-seeded LFSR so backpressure and response latency vary
    // while remaining exactly reproducible.
    always @* begin
        ext_req_ready = rst_n && !force_first_stall &&
                        (stall_lfsr[2:0] != 3'b000);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_read         <= 1'b0;
            pending_read_addr    <= '0;
            read_delay           <= '0;
            ext_rsp_valid        <= 1'b0;
            ext_rsp_rdata        <= '0;
            stall_lfsr           <= (stall_seed == 0) ? 32'h1 : stall_seed;
            read_stall_forced    <= 1'b0;
            write_stall_forced   <= 1'b0;
            memory_cycle         <= 0;
            read_requests        <= 0;
            write_requests       <= 0;
            read_request_stalls  <= 0;
            write_request_stalls <= 0;
            protocol_errors      <= 0;
        end else begin
            memory_cycle <= memory_cycle + 1;
            ext_rsp_valid <= 1'b0;
            stall_lfsr <= {
                stall_lfsr[30:0],
                stall_lfsr[31] ^ stall_lfsr[21] ^
                stall_lfsr[1] ^ stall_lfsr[0]
            };

            if (pending_read) begin
                if (read_delay == 0) begin
                    if ((pending_read_addr[1:0] != 0) ||
                        ((pending_read_addr >> 2) >= EXT_WORDS)) begin
                        $display("ERROR: invalid pending read address 0x%0h",
                                 pending_read_addr);
                        protocol_errors <= protocol_errors + 1;
                        ext_rsp_rdata <= 'x;
                    end else begin
                        ext_rsp_rdata <=
                            external_memory[pending_read_addr[EXT_WORD_ADDR_W+1:2]];
                    end
                    ext_rsp_valid <= 1'b1;
                    pending_read <= 1'b0;
                end else begin
                    read_delay <= read_delay - 1'b1;
                end
            end

            if (ext_req_valid && !ext_req_ready) begin
                if (ext_req_write) begin
                    write_stall_forced <= 1'b1;
                    write_request_stalls <= write_request_stalls + 1;
                end else begin
                    read_stall_forced <= 1'b1;
                    read_request_stalls <= read_request_stalls + 1;
                end
            end

            if (ext_req_valid && ext_req_ready) begin
                if ((ext_req_addr[1:0] != 0) ||
                    ((ext_req_addr >> 2) >= EXT_WORDS)) begin
                    $display("ERROR: invalid external request address 0x%0h",
                             ext_req_addr);
                    protocol_errors <= protocol_errors + 1;
                end else if (ext_req_write) begin
                    external_memory[ext_req_addr[EXT_WORD_ADDR_W+1:2]] <=
                        ext_req_wdata;
                    write_requests <= write_requests + 1;
                end else if (pending_read) begin
                    $display("ERROR: external model received overlapping reads");
                    protocol_errors <= protocol_errors + 1;
                end else begin
                    pending_read <= 1'b1;
                    pending_read_addr <= ext_req_addr;
                    read_delay <= stall_lfsr[5:3];
                    read_requests <= read_requests + 1;
                end
            end
        end
    end

    task automatic write_program(
        input integer target,
        input logic [127:0] data
    );
        begin
            @(negedge clk);
            program_we = 1'b1;
            program_addr = target[$clog2(IMEM_DEPTH)-1:0];
            program_wdata = data;
            @(negedge clk);
            program_we = 1'b0;
        end
    endtask

    task automatic start_dma(
        input logic to_local,
        input logic [1:0] memory,
        input integer local_base,
        input logic [EXT_ADDR_W-1:0] external_base,
        input integer length
    );
        begin
            timeout = 0;
            while (!dma_cmd_ready && timeout < 200) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!dma_cmd_ready) begin
                $display("ERROR: DMA command interface did not become ready");
                errors = errors + 1;
            end else begin
                @(negedge clk);
                dma_cmd_valid = 1'b1;
                dma_cmd_to_local = to_local;
                dma_cmd_mem = memory;
                dma_cmd_local_addr = local_base[ADDR_W-1:0];
                dma_cmd_ext_addr = external_base;
                dma_cmd_length = length[15:0];
                @(negedge clk);
                dma_cmd_valid = 1'b0;
            end
        end
    endtask

    task automatic wait_for_dma;
        begin
            timeout = 0;
            while (!dma_done && timeout < 20000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!dma_done) begin
                $display("ERROR: DMA operation timed out");
                errors = errors + 1;
            end
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    initial begin
        $readmemh("config.hex", config_image);
        $readmemh("program.hex", program_image);
        $readmemh("a.hex", a_image);
        $readmemh("b.hex", b_image);
        $readmemh("c_initial.hex", c_initial_image);
        $readmemh("c_expected.hex", c_expected_image);

        seed = config_image[CFG_SEED];
        case_index = config_image[CFG_CASE_INDEX];
        m_size = config_image[CFG_M];
        k_size = config_image[CFG_K];
        n_size = config_image[CFG_N];
        lda = config_image[CFG_LDA];
        ldb = config_image[CFG_LDB];
        ldc = config_image[CFG_LDC];
        program_words = config_image[CFG_PROGRAM_WORDS];
        a_base = config_image[CFG_A_BASE];
        a_words = config_image[CFG_A_WORDS];
        b_base = config_image[CFG_B_BASE];
        b_words = config_image[CFG_B_WORDS];
        c_base = config_image[CFG_C_BASE];
        c_words = config_image[CFG_C_WORDS];
        stall_seed = config_image[CFG_STALL_SEED];

        clk = 1'b0;
        rst_n = 1'b1;
        program_we = 1'b0;
        program_addr = '0;
        program_wdata = '0;
        start = 1'b0;
        dma_cmd_valid = 1'b0;
        dma_cmd_to_local = 1'b0;
        dma_cmd_mem = '0;
        dma_cmd_local_addr = '0;
        dma_cmd_ext_addr = '0;
        dma_cmd_length = '0;
        errors = 0;

        if ((program_words <= 0) || (program_words > IMEM_DEPTH) ||
            (a_base < 0) || (a_words <= 0) ||
            (a_base + a_words > SCRATCHPAD_WORDS) ||
            (b_base < 0) || (b_words <= 0) ||
            (b_base + b_words > SCRATCHPAD_WORDS) ||
            (c_base < 0) || (c_words <= 0) ||
            (c_base + c_words > SCRATCHPAD_WORDS)) begin
            $display("ERROR: generated case configuration is out of range");
            errors = errors + 1;
        end

        for (address = 0; address < EXT_WORDS; address = address + 1)
            external_memory[address] = 32'hde00_0000 ^ address;
        for (address = 0; address < a_words; address = address + 1)
            external_memory[(EXT_A_BASE >> 2) + address] =
                a_image[a_base + address];
        for (address = 0; address < b_words; address = address + 1)
            external_memory[(EXT_B_BASE >> 2) + address] =
                b_image[b_base + address];
        for (address = 0; address < c_words; address = address + 1)
            external_memory[(EXT_C_BASE >> 2) + address] =
                c_initial_image[c_base + address];

        #1 rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        for (address = 0; address < program_words; address = address + 1)
            write_program(address, program_image[address]);

        start_dma(1'b1, MEM_A, a_base, EXT_A_BASE, a_words);
        wait_for_dma();
        start_dma(1'b1, MEM_B, b_base, EXT_B_BASE, b_words);
        wait_for_dma();
        start_dma(1'b1, MEM_C, c_base, EXT_C_BASE, c_words);
        wait_for_dma();

        pulse_start();
        compute_cycles = 0;
        while (!done && compute_cycles < 20000) begin
            @(negedge clk);
            compute_cycles = compute_cycles + 1;
        end
        if (!done) begin
            $display("ERROR: compute timed out");
            errors = errors + 1;
        end
        if (fault || (fault_code != 0)) begin
            $display("ERROR: compute faulted with code 0x%0h", fault_code);
            errors = errors + 1;
        end

        start_dma(1'b0, MEM_C, c_base, EXT_C_BASE, c_words);
        wait_for_dma();

        for (address = 0; address < c_words; address = address + 1) begin
            actual_word = external_memory[(EXT_C_BASE >> 2) + address];
            expected_word = c_expected_image[c_base + address];
            if (actual_word !== expected_word) begin
                $display(
                    "ERROR: C local[%0d] expected %0d (0x%08x), got %0d (0x%08x)",
                    c_base + address, $signed(expected_word), expected_word,
                    $signed(actual_word), actual_word
                );
                errors = errors + 1;
            end
        end

        if (read_requests != a_words + b_words + c_words) begin
            $display("ERROR: expected %0d reads, observed %0d",
                     a_words + b_words + c_words, read_requests);
            errors = errors + 1;
        end
        if (write_requests != c_words) begin
            $display("ERROR: expected %0d writes, observed %0d",
                     c_words, write_requests);
            errors = errors + 1;
        end
        if ((read_request_stalls == 0) || (write_request_stalls == 0)) begin
            $display("ERROR: read/write backpressure was not exercised");
            errors = errors + 1;
        end
        if (protocol_errors != 0)
            errors = errors + protocol_errors;

        if (errors == 0) begin
            $display(
                "PASS: seed=0x%08x case=%0d shape=%0dx%0dx%0d strides=%0d/%0d/%0d program=%0d",
                seed, case_index, m_size, k_size, n_size,
                lda, ldb, ldc, program_words
            );
            $display(
                "INFO: compute_cycles=%0d read_stalls=%0d write_stalls=%0d",
                compute_cycles, read_request_stalls, write_request_stalls
            );
        end else begin
            $display("FAIL: seed=0x%08x case=%0d errors=%0d",
                     seed, case_index, errors);
        end
        $finish(errors != 0);
    end

endmodule
