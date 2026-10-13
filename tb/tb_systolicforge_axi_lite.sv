`timescale 1ns/1ps

module tb_systolicforge_axi_lite;

    localparam integer ARRAY_ROWS = 4;
    localparam integer ARRAY_COLS = 4;
    localparam integer ADDR_W = 4;
    localparam integer IMEM_DEPTH = 4;
    localparam integer EXT_ADDR_W = 8;
    localparam integer AXI_ADDR_W = 8;

    localparam logic [7:0] REG_ID             = 8'h00;
    localparam logic [7:0] REG_VERSION        = 8'h04;
    localparam logic [7:0] REG_CONTROL        = 8'h08;
    localparam logic [7:0] REG_STATUS         = 8'h0c;
    localparam logic [7:0] REG_IRQ_ENABLE     = 8'h10;
    localparam logic [7:0] REG_IRQ_STATUS     = 8'h14;
    localparam logic [7:0] REG_PROGRAM_ADDR   = 8'h20;
    localparam logic [7:0] REG_PROGRAM_DATA_0 = 8'h24;
    localparam logic [7:0] REG_PROGRAM_DATA_1 = 8'h28;
    localparam logic [7:0] REG_PROGRAM_DATA_2 = 8'h2c;
    localparam logic [7:0] REG_PROGRAM_DATA_3 = 8'h30;
    localparam logic [7:0] REG_PROGRAM_COMMIT = 8'h34;
    localparam logic [7:0] REG_DMA_CONFIG     = 8'h40;
    localparam logic [7:0] REG_DMA_LOCAL_ADDR = 8'h44;
    localparam logic [7:0] REG_DMA_EXT_ADDR   = 8'h48;
    localparam logic [7:0] REG_DMA_LENGTH     = 8'h4c;
    localparam logic [7:0] REG_DMA_SUBMIT     = 8'h50;

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;
    localparam logic [1:0] AXI_DECERR = 2'b11;

    localparam logic [2:0] IRQ_COMPUTE_DONE = 3'b001;
    localparam logic [2:0] IRQ_DMA_DONE     = 3'b010;
    localparam logic [2:0] IRQ_FAULT        = 3'b100;

    logic clk;
    logic rst_n;

    logic [AXI_ADDR_W-1:0] s_axi_awaddr;
    logic [2:0] s_axi_awprot;
    logic s_axi_awvalid;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata;
    logic [3:0] s_axi_wstrb;
    logic s_axi_wvalid;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready;

    logic [AXI_ADDR_W-1:0] s_axi_araddr;
    logic [2:0] s_axi_arprot;
    logic s_axi_arvalid;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready;

    logic irq;
    logic ext_req_valid;
    logic ext_req_ready;
    logic ext_req_write;
    logic [EXT_ADDR_W-1:0] ext_req_addr;
    logic [31:0] ext_req_wdata;
    logic ext_rsp_valid;
    logic [31:0] ext_rsp_rdata;

    integer errors;
    integer timeout;
    integer external_reads;
    integer external_writes;
    logic [31:0] stored_c_word;

    systolicforge_axi_lite #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH),
        .EXT_ADDR_W(EXT_ADDR_W),
        .AXI_ADDR_W(AXI_ADDR_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .irq(irq),
        .ext_req_valid(ext_req_valid),
        .ext_req_ready(ext_req_ready),
        .ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),
        .ext_req_wdata(ext_req_wdata),
        .ext_rsp_valid(ext_rsp_valid),
        .ext_rsp_rdata(ext_rsp_rdata)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_rsp_valid  <= 1'b0;
            ext_rsp_rdata  <= '0;
            external_reads <= 0;
            external_writes <= 0;
            stored_c_word  <= '0;
        end else begin
            ext_rsp_valid <= 1'b0;
            if (ext_req_valid && ext_req_ready) begin
                if (ext_req_write) begin
                    external_writes <= external_writes + 1;
                    stored_c_word <= ext_req_wdata;
                end else begin
                    external_reads <= external_reads + 1;
                    ext_rsp_valid <= 1'b1;
                    case (ext_req_addr)
                        8'h20: ext_rsp_rdata <= 32'd2;
                        8'h24: ext_rsp_rdata <= 32'd3;
                        default: ext_rsp_rdata <= 32'hdead_beef;
                    endcase
                end
            end
        end
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

    task automatic drive_aw(input logic [7:0] address);
        begin
            @(negedge clk);
            s_axi_awaddr = address;
            s_axi_awvalid = 1'b1;
            while (!s_axi_awready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task automatic drive_w(
        input logic [31:0] data,
        input logic [3:0] strobes
    );
        begin
            @(negedge clk);
            s_axi_wdata = data;
            s_axi_wstrb = strobes;
            s_axi_wvalid = 1'b1;
            while (!s_axi_wready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_wvalid = 1'b0;
        end
    endtask

    task automatic collect_b(output logic [1:0] response);
        begin
            s_axi_bready = 1'b0;
            while (!s_axi_bvalid)
                @(negedge clk);
            response = s_axi_bresp;
            s_axi_bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_write(
        input logic [7:0] address,
        input logic [31:0] data,
        input logic [3:0] strobes,
        input integer channel_order,
        output logic [1:0] response
    );
        begin
            case (channel_order)
                1: begin
                    drive_aw(address);
                    drive_w(data, strobes);
                end
                2: begin
                    drive_w(data, strobes);
                    drive_aw(address);
                end
                default: begin
                    fork
                        drive_aw(address);
                        drive_w(data, strobes);
                    join
                end
            endcase
            collect_b(response);
        end
    endtask

    task automatic expect_write(
        input logic [7:0] address,
        input logic [31:0] data,
        input logic [3:0] strobes,
        input integer channel_order,
        input logic [1:0] expected_response
    );
        logic [1:0] actual_response;
        begin
            axi_write(address, data, strobes, channel_order, actual_response);
            if (actual_response !== expected_response) begin
                $display(
                    "ERROR: write 0x%02h expected BRESP=%02b, got %02b",
                    address, expected_response, actual_response
                );
                errors = errors + 1;
            end
        end
    endtask

    task automatic drive_ar(input logic [7:0] address);
        begin
            @(negedge clk);
            s_axi_araddr = address;
            s_axi_arvalid = 1'b1;
            while (!s_axi_arready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;
        end
    endtask

    task automatic axi_read(
        input logic [7:0] address,
        output logic [31:0] data,
        output logic [1:0] response
    );
        begin
            drive_ar(address);
            s_axi_rready = 1'b0;
            while (!s_axi_rvalid)
                @(negedge clk);
            data = s_axi_rdata;
            response = s_axi_rresp;
            s_axi_rready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    task automatic expect_read(
        input logic [7:0] address,
        input logic [31:0] expected_data,
        input logic [31:0] compare_mask,
        input logic [1:0] expected_response
    );
        logic [31:0] actual_data;
        logic [1:0] actual_response;
        begin
            axi_read(address, actual_data, actual_response);
            if (actual_response !== expected_response) begin
                $display(
                    "ERROR: read 0x%02h expected RRESP=%02b, got %02b",
                    address, expected_response, actual_response
                );
                errors = errors + 1;
            end
            if ((actual_data & compare_mask) !==
                (expected_data & compare_mask)) begin
                $display(
                    "ERROR: read 0x%02h expected 0x%08h/mask 0x%08h, got 0x%08h",
                    address, expected_data, compare_mask, actual_data
                );
                errors = errors + 1;
            end
        end
    endtask

    task automatic stage_instruction(
        input logic [31:0] target,
        input logic [127:0] instruction
    );
        begin
            expect_write(REG_PROGRAM_ADDR, target, 4'hf, 2, AXI_OKAY);
            expect_write(REG_PROGRAM_DATA_0, instruction[31:0], 4'hf, 0,
                         AXI_OKAY);
            expect_write(REG_PROGRAM_DATA_1, instruction[63:32], 4'hf, 1,
                         AXI_OKAY);
            expect_write(REG_PROGRAM_DATA_2, instruction[95:64], 4'hf, 2,
                         AXI_OKAY);
            expect_write(REG_PROGRAM_DATA_3, instruction[127:96], 4'hf, 0,
                         AXI_OKAY);
            expect_write(REG_PROGRAM_COMMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        end
    endtask

    task automatic wait_for_irq;
        begin
            timeout = 0;
            while (!irq && timeout < 5000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!irq) begin
                $display("ERROR: interrupt timed out");
                errors = errors + 1;
            end
        end
    endtask

    task automatic wait_for_fault_clear;
        logic [31:0] data;
        logic [1:0] response;
        begin
            timeout = 0;
            data = 32'hffff_ffff;
            while (data[2] && timeout < 20) begin
                axi_read(REG_STATUS, data, response);
                if (response !== AXI_OKAY) begin
                    $display("ERROR: status read failed during fault recovery");
                    errors = errors + 1;
                end
                timeout = timeout + 1;
            end
            if (data[2]) begin
                $display("ERROR: hardware fault did not clear after recovery command");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awaddr = '0;
        s_axi_awprot = '0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata = '0;
        s_axi_wstrb = '0;
        s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b0;
        s_axi_araddr = '0;
        s_axi_arprot = '0;
        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        ext_req_ready = 1'b1;
        errors = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        expect_read(REG_ID, 32'h5346_4e50, 32'hffff_ffff, AXI_OKAY);
        expect_read(REG_VERSION, 32'h0001_0000, 32'hffff_ffff, AXI_OKAY);
        expect_read(REG_STATUS, 32'h0000_0100, 32'h0000_01ff, AXI_OKAY);

        // WSTRB behavior and independent AW/W channel ordering.
        expect_write(REG_PROGRAM_DATA_0, 32'haabb_ccdd, 4'hf, 1, AXI_OKAY);
        expect_write(REG_PROGRAM_DATA_0, 32'h0000_1200, 4'b0010, 2,
                     AXI_OKAY);
        expect_read(REG_PROGRAM_DATA_0, 32'haabb_12dd, 32'hffff_ffff,
                    AXI_OKAY);

        expect_read(8'h18, 32'd0, 32'hffff_ffff, AXI_DECERR);
        expect_write(REG_ID, 32'd0, 4'hf, 0, AXI_SLVERR);
        expect_write(8'h21, 32'd0, 4'hf, 0, AXI_DECERR);

        // A staged program address must remain inside IMEM_DEPTH.
        expect_write(REG_PROGRAM_ADDR, IMEM_DEPTH, 4'hf, 0, AXI_OKAY);
        expect_write(REG_PROGRAM_COMMIT, 32'd1, 4'hf, 0, AXI_SLVERR);

        // A one-word HALT program proves programming, start, status, and IRQ.
        stage_instruction(0, 128'hf);
        expect_write(REG_IRQ_ENABLE, 32'h7, 4'hf, 0, AXI_OKAY);
        expect_write(REG_CONTROL, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_irq();
        expect_read(REG_IRQ_STATUS, IRQ_COMPUTE_DONE, 32'h7, AXI_OKAY);
        expect_read(REG_STATUS, 32'h8, 32'hc, AXI_OKAY);
        expect_write(REG_IRQ_STATUS, IRQ_COMPUTE_DONE, 4'h1, 0, AXI_OKAY);
        expect_read(REG_IRQ_STATUS, 32'd0, 32'h7, AXI_OKAY);
        if (irq) begin
            $display("ERROR: compute interrupt did not clear");
            errors = errors + 1;
        end

        // Load A=2 and B=3 through host-issued DMA commands.
        expect_write(REG_DMA_CONFIG, 32'h1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LOCAL_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_EXT_ADDR, 32'h20, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'd1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_irq();
        expect_read(REG_IRQ_STATUS, IRQ_DMA_DONE, 32'h7, AXI_OKAY);
        expect_write(REG_IRQ_STATUS, IRQ_DMA_DONE, 4'h1, 0, AXI_OKAY);

        expect_write(REG_DMA_CONFIG, 32'h3, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_EXT_ADDR, 32'h24, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_irq();
        expect_read(REG_IRQ_STATUS, IRQ_DMA_DONE, 32'h7, AXI_OKAY);
        expect_write(REG_IRQ_STATUS, IRQ_DMA_DONE, 4'h1, 0, AXI_OKAY);

        // Long valid program leaves time to verify command rejection while busy.
        stage_instruction(0, matmul_instruction(64, 1, 1, 0, 0, 0,
                                                0, 0, 0));
        stage_instruction(1, 128'hf);
        expect_write(REG_CONTROL, 32'd1, 4'hf, 0, AXI_OKAY);
        expect_read(REG_STATUS, 32'h1, 32'h1, AXI_OKAY);
        expect_write(REG_CONTROL, 32'd1, 4'hf, 0, AXI_SLVERR);
        expect_write(REG_PROGRAM_COMMIT, 32'd1, 4'hf, 0, AXI_SLVERR);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_SLVERR);
        wait_for_irq();
        expect_read(REG_IRQ_STATUS, IRQ_COMPUTE_DONE, 32'h7, AXI_OKAY);
        expect_read(REG_STATUS, 32'd0, 32'h77, AXI_OKAY);
        expect_write(REG_IRQ_STATUS, IRQ_COMPUTE_DONE, 4'h1, 0, AXI_OKAY);

        // Store C[0] back to external memory; 2*3 must equal 6.
        expect_write(REG_DMA_CONFIG, 32'h4, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LOCAL_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_EXT_ADDR, 32'h28, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'd1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_irq();
        expect_write(REG_IRQ_STATUS, IRQ_DMA_DONE, 4'h1, 0, AXI_OKAY);
        if (stored_c_word !== 32'd6) begin
            $display("ERROR: expected DMA-stored C[0]=6, got 0x%08h",
                     stored_c_word);
            errors = errors + 1;
        end

        // Invalid DMA memory reaches the core's structured fault reporting.
        expect_write(REG_DMA_CONFIG, 32'h7, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LOCAL_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_EXT_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'd1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_irq();
        expect_read(REG_IRQ_STATUS, IRQ_DMA_DONE | IRQ_FAULT, 32'h7,
                    AXI_OKAY);
        expect_read(REG_STATUS, 32'h5c, 32'hfc, AXI_OKAY);

        // W1C cannot hide a fault while the hardware condition is active.
        expect_write(REG_IRQ_STATUS, IRQ_DMA_DONE | IRQ_FAULT, 4'h1, 0,
                     AXI_OKAY);
        expect_read(REG_IRQ_STATUS, IRQ_FAULT, 32'h7, AXI_OKAY);

        // A valid zero-length command clears the DMA fault without bus traffic.
        expect_write(REG_DMA_CONFIG, 32'h1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_OKAY);
        wait_for_fault_clear();
        expect_write(REG_IRQ_STATUS, IRQ_DMA_DONE | IRQ_FAULT, 4'h1, 0,
                     AXI_OKAY);
        expect_read(REG_IRQ_STATUS, 32'd0, 32'h7, AXI_OKAY);

        // Wrapper-level field-width checks reject values before truncation.
        expect_write(REG_DMA_LOCAL_ADDR, 32'h10, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'd1, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_SLVERR);
        expect_write(REG_DMA_LOCAL_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_EXT_ADDR, 32'h100, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_SLVERR);
        expect_write(REG_DMA_EXT_ADDR, 32'd0, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_LENGTH, 32'h0001_0000, 4'hf, 0, AXI_OKAY);
        expect_write(REG_DMA_SUBMIT, 32'd1, 4'hf, 0, AXI_SLVERR);

        if ((external_reads != 2) || (external_writes != 1)) begin
            $display(
                "ERROR: expected 2 reads/1 write, observed %0d reads/%0d writes",
                external_reads, external_writes
            );
            errors = errors + 1;
        end

        if (irq) begin
            $display("ERROR: IRQ remained asserted at end of regression");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: AXI4-Lite host control, DMA, faults, and IRQs");
        else
            $fatal(1, "FAIL: %0d AXI4-Lite integration error(s)", errors);
        $finish;
    end

endmodule
