`timescale 1ns/1ps

module tb_systolicforge_soc;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 8;
    localparam integer ADDR_W = 8;
    localparam integer IMEM_DEPTH = 16;
    localparam integer EXT_ADDR_W = 32;
    localparam integer EXT_WORDS = 1024;
    localparam integer EXT_WORD_ADDR_W = $clog2(EXT_WORDS);
    localparam integer M = 6;
    localparam integer K = 10;
    localparam integer N = 10;
    localparam integer PROGRAM_WORDS = 5;
    localparam integer A_WORDS = M*K;
    localparam integer B_WORDS = K*N;
    localparam integer C_WORDS = M*N;
    localparam integer EXT_A_BASE = 16'h0100;
    localparam integer EXT_B_BASE = 16'h0400;
    localparam integer EXT_C_BASE = 16'h0800;

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

    logic [127:0] program_image [0:PROGRAM_WORDS-1];
    logic [7:0] a_image [0:A_WORDS-1];
    logic [7:0] b_image [0:B_WORDS-1];
    logic [31:0] expected_image [0:C_WORDS-1];
    logic [31:0] external_memory [0:EXT_WORDS-1];

    logic pending_read;
    logic [EXT_ADDR_W-1:0] pending_read_addr;
    logic [2:0] read_delay;
    integer memory_cycle;
    integer read_requests;
    integer write_requests;
    integer read_request_stalls;
    integer write_request_stalls;
    integer protocol_errors;

    integer address;
    integer errors;
    integer timeout;
    integer compute_cycles;
    integer signed actual;
    integer signed expected;

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

    // Apply deterministic request backpressure on one out of every four cycles.
    assign ext_req_ready = rst_n && (memory_cycle[1:0] != 2'b01);

    // External memory accepts one outstanding read and returns it after a
    // deterministic one-to-four-cycle delay. Writes commit on request handshake.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_read        <= 1'b0;
            pending_read_addr   <= '0;
            read_delay          <= '0;
            ext_rsp_valid       <= 1'b0;
            ext_rsp_rdata       <= '0;
            memory_cycle        <= 0;
            read_requests       <= 0;
            write_requests      <= 0;
            read_request_stalls <= 0;
            write_request_stalls <= 0;
            protocol_errors     <= 0;
        end else begin
            memory_cycle  <= memory_cycle + 1;
            ext_rsp_valid <= 1'b0;

            if (pending_read) begin
                if (read_delay == 0) begin
                    if ((pending_read_addr[1:0] != 0) ||
                        ((pending_read_addr >> 2) >= EXT_WORDS)) begin
                        $display("ERROR: invalid pending external read address 0x%0h",
                                 pending_read_addr);
                        protocol_errors <= protocol_errors + 1;
                        ext_rsp_rdata <= 'x;
                    end else begin
                        ext_rsp_rdata <=
                            external_memory[pending_read_addr[EXT_WORD_ADDR_W+1:2]];
                    end
                    ext_rsp_valid <= 1'b1;
                    pending_read  <= 1'b0;
                end else begin
                    read_delay <= read_delay - 1'b1;
                end
            end

            if (ext_req_valid && !ext_req_ready) begin
                if (ext_req_write)
                    write_request_stalls <= write_request_stalls + 1;
                else
                    read_request_stalls <= read_request_stalls + 1;
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
                    pending_read      <= 1'b1;
                    pending_read_addr <= ext_req_addr;
                    read_delay <= {1'b0, ext_req_addr[3:2]};
                    read_requests <= read_requests + 1;
                end
            end
        end
    end

    task automatic write_program(
        input logic [$clog2(IMEM_DEPTH)-1:0] target,
        input logic [127:0] data
    );
        begin
            @(negedge clk);
            program_we    = 1'b1;
            program_addr  = target;
            program_wdata = data;
            @(negedge clk);
            program_we    = 1'b0;
        end
    endtask

    task automatic start_dma(
        input logic to_local,
        input logic [1:0] memory,
        input logic [ADDR_W-1:0] local_base,
        input logic [EXT_ADDR_W-1:0] external_base,
        input logic [15:0] length
    );
        begin
            timeout = 0;
            while (!dma_cmd_ready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!dma_cmd_ready) begin
                $display("ERROR: DMA command interface did not become ready");
                errors = errors + 1;
            end else begin
                @(negedge clk);
                dma_cmd_valid      = 1'b1;
                dma_cmd_to_local   = to_local;
                dma_cmd_mem        = memory;
                dma_cmd_local_addr = local_base;
                dma_cmd_ext_addr   = external_base;
                dma_cmd_length     = length;
                @(negedge clk);
                dma_cmd_valid      = 1'b0;
                if ((length != 0) && !dma_busy) begin
                    $display("ERROR: DMA did not enter busy after command acceptance");
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic wait_for_dma;
        begin
            timeout = 0;
            while (!dma_done && timeout < 5000) begin
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
        $readmemh("build/example_program/program.hex", program_image);
        $readmemh("build/example_program/a.hex", a_image);
        $readmemh("build/example_program/b.hex", b_image);
        $readmemh("build/example_program/c_expected.hex", expected_image);

        clk                    = 1'b0;
        rst_n                  = 1'b0;
        program_we             = 1'b0;
        program_addr           = '0;
        program_wdata          = '0;
        start                  = 1'b0;
        dma_cmd_valid          = 1'b0;
        dma_cmd_to_local       = 1'b0;
        dma_cmd_mem            = '0;
        dma_cmd_local_addr     = '0;
        dma_cmd_ext_addr       = '0;
        dma_cmd_length         = '0;
        errors                 = 0;

        for (address = 0; address < EXT_WORDS; address = address + 1)
            external_memory[address] = 32'hdead_0000 + address;
        for (address = 0; address < A_WORDS; address = address + 1)
            external_memory[(EXT_A_BASE >> 2) + address] =
                {24'd0, a_image[address]};
        for (address = 0; address < B_WORDS; address = address + 1)
            external_memory[(EXT_B_BASE >> 2) + address] =
                {24'd0, b_image[address]};

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        for (address = 0; address < PROGRAM_WORDS; address = address + 1)
            write_program(address[$clog2(IMEM_DEPTH)-1:0],
                          program_image[address]);

        start_dma(1'b1, MEM_A, 0, EXT_A_BASE, A_WORDS[15:0]);
        wait_for_dma();

        start_dma(1'b1, MEM_B, 0, EXT_B_BASE, B_WORDS[15:0]);
        if (!dma_busy) begin
            $display("ERROR: B load was not active for arbitration check");
            errors = errors + 1;
        end
        pulse_start();
        repeat (2) @(negedge clk);
        if (busy) begin
            $display("ERROR: compute start was accepted while DMA was busy");
            errors = errors + 1;
        end
        wait_for_dma();

        pulse_start();
        compute_cycles = 0;
        while (!done && compute_cycles < 1000) begin
            @(negedge clk);
            compute_cycles = compute_cycles + 1;
            if (busy && dma_cmd_ready) begin
                $display("ERROR: DMA command became ready while compute was busy");
                errors = errors + 1;
            end
        end
        if (!done) begin
            $display("ERROR: integrated SoC compute timed out");
            errors = errors + 1;
        end
        if (fault) begin
            $display("ERROR: integrated SoC compute raised fault");
            errors = errors + 1;
        end

        start_dma(1'b0, MEM_C, 0, EXT_C_BASE, C_WORDS[15:0]);
        wait_for_dma();

        for (address = 0; address < C_WORDS; address = address + 1) begin
            actual = $signed(external_memory[(EXT_C_BASE >> 2) + address]);
            expected = $signed(expected_image[address]);
            if (actual !== expected) begin
                $display("ERROR: external C[%0d] expected %0d, got %0d",
                         address, expected, actual);
                errors = errors + 1;
            end
        end

        if (read_requests != A_WORDS + B_WORDS) begin
            $display("ERROR: expected %0d external reads, observed %0d",
                     A_WORDS + B_WORDS, read_requests);
            errors = errors + 1;
        end
        if (write_requests != C_WORDS) begin
            $display("ERROR: expected %0d external writes, observed %0d",
                     C_WORDS, write_requests);
            errors = errors + 1;
        end
        if ((read_request_stalls == 0) || (write_request_stalls == 0)) begin
            $display("ERROR: external-memory backpressure was not exercised");
            errors = errors + 1;
        end
        if (protocol_errors != 0)
            errors = errors + protocol_errors;

        if (errors == 0) begin
            $display(
                "PASS: integrated SoC DMA-loaded A/B, executed %0d-word program, and stored all %0d C results",
                PROGRAM_WORDS, C_WORDS
            );
            $display(
                "INFO: %0d compute cycles, %0d read stalls, %0d write stalls",
                compute_cycles, read_request_stalls, write_request_stalls
            );
        end else begin
            $display("FAIL: %0d integrated SoC error(s)", errors);
        end
        $finish(errors != 0);
    end

endmodule
