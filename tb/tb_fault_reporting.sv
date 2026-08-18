`timescale 1ns/1ps

module tb_fault_reporting;

    localparam integer ARRAY_ROWS = 4;
    localparam integer ARRAY_COLS = 4;
    localparam integer ADDR_W = 4;
    localparam integer IMEM_DEPTH = 4;
    localparam integer EXT_ADDR_W = 8;

    localparam logic [3:0] FAULT_NONE                 = 4'h0;
    localparam logic [3:0] FAULT_ILLEGAL_OPCODE       = 4'h1;
    localparam logic [3:0] FAULT_ILLEGAL_DIMENSION    = 4'h2;
    localparam logic [3:0] FAULT_ADDRESS_RANGE        = 4'h3;
    localparam logic [3:0] FAULT_PROGRAM_OVERRUN      = 4'h4;
    localparam logic [3:0] FAULT_DMA_INVALID_MEMORY   = 4'h5;
    localparam logic [3:0] FAULT_DMA_LOCAL_RANGE      = 4'h6;
    localparam logic [3:0] FAULT_DMA_EXTERNAL_ADDRESS = 4'h7;

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
    logic ext_req_write;
    logic [EXT_ADDR_W-1:0] ext_req_addr;
    logic [31:0] ext_req_wdata;

    integer errors;
    integer timeout;
    integer external_requests;

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
        .ext_req_ready(1'b1),
        .ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),
        .ext_req_wdata(ext_req_wdata),
        .ext_rsp_valid(1'b0),
        .ext_rsp_rdata(32'd0)
    );

    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            external_requests <= 0;
        else if (ext_req_valid)
            external_requests <= external_requests + 1;
    end

    function automatic [127:0] matmul_instruction(
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
        reg [127:0] instruction;
        begin
            instruction = '0;
            instruction[3:0] = 4'h1;
            instruction[15:8] = m_size[7:0];
            instruction[23:16] = k_size[7:0];
            instruction[31:24] = n_size[7:0];
            instruction[47:32] = a_base[15:0];
            instruction[63:48] = b_base[15:0];
            instruction[79:64] = c_base[15:0];
            instruction[95:80] = lda[15:0];
            instruction[111:96] = ldb[15:0];
            instruction[127:112] = ldc[15:0];
            matmul_instruction = instruction;
        end
    endfunction

    task automatic write_program(input integer target, input [127:0] data);
        begin
            @(negedge clk);
            program_we = 1'b1;
            program_addr = target[$clog2(IMEM_DEPTH)-1:0];
            program_wdata = data;
            @(negedge clk);
            program_we = 1'b0;
        end
    endtask

    task automatic run_program;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout = 0;
            while (!done && timeout < 50) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done) begin
                $display("ERROR: program did not terminate");
                errors = errors + 1;
            end
        end
    endtask

    task automatic expect_npu_fault(input logic [3:0] expected_code);
        begin
            run_program();
            if (!fault || (fault_code !== expected_code)) begin
                $display("ERROR: expected NPU fault 0x%0h, got fault=%0b code=0x%0h",
                         expected_code, fault, fault_code);
                errors = errors + 1;
            end
            if (busy) begin
                $display("ERROR: NPU remained busy after fault 0x%0h", expected_code);
                errors = errors + 1;
            end
        end
    endtask

    task automatic issue_dma(
        input logic [1:0] memory,
        input logic [ADDR_W-1:0] local_address,
        input logic [EXT_ADDR_W-1:0] external_address,
        input logic [15:0] length
    );
        begin
            timeout = 0;
            while (!dma_cmd_ready && timeout < 20) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!dma_cmd_ready) begin
                $display("ERROR: DMA command interface did not become ready");
                errors = errors + 1;
            end else begin
                @(negedge clk);
                dma_cmd_valid = 1'b1;
                dma_cmd_to_local = 1'b1;
                dma_cmd_mem = memory;
                dma_cmd_local_addr = local_address;
                dma_cmd_ext_addr = external_address;
                dma_cmd_length = length;
                @(negedge clk);
                dma_cmd_valid = 1'b0;
                timeout = 0;
                while (!dma_done && timeout < 20) begin
                    @(negedge clk);
                    timeout = timeout + 1;
                end
                if (!dma_done) begin
                    $display("ERROR: rejected DMA command did not terminate");
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic expect_dma_fault(input logic [3:0] expected_code);
        begin
            if (!fault || (fault_code !== expected_code)) begin
                $display("ERROR: expected DMA fault 0x%0h, got fault=%0b code=0x%0h",
                         expected_code, fault, fault_code);
                errors = errors + 1;
            end
            if (dma_busy) begin
                $display("ERROR: DMA entered busy for rejected command");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
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

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        write_program(0, 128'h2);
        expect_npu_fault(FAULT_ILLEGAL_OPCODE);

        write_program(0, matmul_instruction(0, 1, 1, 0, 0, 0, 1, 1, 1));
        expect_npu_fault(FAULT_ILLEGAL_DIMENSION);

        write_program(0, matmul_instruction(2, 2, 2, 15, 0, 0, 2, 2, 2));
        expect_npu_fault(FAULT_ADDRESS_RANGE);

        // This product wraps to zero if the 8x16-bit address calculation is
        // not widened before multiplication.
        write_program(0, matmul_instruction(255, 1, 1, 0, 0, 0,
                                            16'h8000, 0, 0));
        expect_npu_fault(FAULT_ADDRESS_RANGE);

        write_program(0, 128'h0);
        write_program(1, 128'h0);
        write_program(2, 128'h0);
        write_program(3, 128'h0);
        expect_npu_fault(FAULT_PROGRAM_OVERRUN);

        write_program(0, 128'hf);
        run_program();
        if (fault || (fault_code !== FAULT_NONE)) begin
            $display("ERROR: valid HALT did not clear the prior NPU fault");
            errors = errors + 1;
        end

        issue_dma(2'd3, 0, 0, 1);
        expect_dma_fault(FAULT_DMA_INVALID_MEMORY);

        issue_dma(2'd0, 15, 0, 2);
        expect_dma_fault(FAULT_DMA_LOCAL_RANGE);

        issue_dma(2'd0, 0, 8'hfc, 2);
        expect_dma_fault(FAULT_DMA_EXTERNAL_ADDRESS);

        issue_dma(2'd0, 0, 8'h02, 1);
        expect_dma_fault(FAULT_DMA_EXTERNAL_ADDRESS);

        issue_dma(2'd0, 15, 8'hff, 0);
        if (fault || (fault_code !== FAULT_NONE) || dma_busy) begin
            $display("ERROR: zero-length DMA was not a successful no-op");
            errors = errors + 1;
        end

        if (external_requests != 0) begin
            $display("ERROR: rejected/no-op DMA emitted %0d external request(s)",
                     external_requests);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: structured NPU/DMA faults reject invalid work and recover");
        else
            $display("FAIL: %0d fault-reporting error(s)", errors);
        $finish(errors != 0);
    end

endmodule
