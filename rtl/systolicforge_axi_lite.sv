`timescale 1ns/1ps

module systolicforge_axi_lite #(
    parameter integer ARRAY_ROWS    = 8,
    parameter integer ARRAY_COLS    = 8,
    parameter integer ADDR_W        = 12,
    parameter integer IMEM_DEPTH    = 256,
    parameter integer EXT_ADDR_W    = 32,
    parameter integer AXI_ADDR_W    = 8
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic [AXI_ADDR_W-1:0]     s_axi_awaddr,
    input  logic [2:0]                s_axi_awprot,
    input  logic                      s_axi_awvalid,
    output logic                      s_axi_awready,
    input  logic [31:0]               s_axi_wdata,
    input  logic [3:0]                s_axi_wstrb,
    input  logic                      s_axi_wvalid,
    output logic                      s_axi_wready,
    output logic [1:0]                s_axi_bresp,
    output logic                      s_axi_bvalid,
    input  logic                      s_axi_bready,

    input  logic [AXI_ADDR_W-1:0]     s_axi_araddr,
    input  logic [2:0]                s_axi_arprot,
    input  logic                      s_axi_arvalid,
    output logic                      s_axi_arready,
    output logic [31:0]               s_axi_rdata,
    output logic [1:0]                s_axi_rresp,
    output logic                      s_axi_rvalid,
    input  logic                      s_axi_rready,

    output logic                      irq,

    output logic                      ext_req_valid,
    input  logic                      ext_req_ready,
    output logic                      ext_req_write,
    output logic [EXT_ADDR_W-1:0]     ext_req_addr,
    output logic [31:0]               ext_req_wdata,
    input  logic                      ext_rsp_valid,
    input  logic [31:0]               ext_rsp_rdata
);

    localparam integer PROGRAM_ADDR_W = $clog2(IMEM_DEPTH);

    localparam logic [1:0] AXI_OKAY   = 2'b00;
    localparam logic [1:0] AXI_SLVERR = 2'b10;
    localparam logic [1:0] AXI_DECERR = 2'b11;

    localparam logic [31:0] CORE_ID      = 32'h5346_4e50;
    localparam logic [31:0] CORE_VERSION = 32'h0001_0000;

    localparam logic [AXI_ADDR_W-1:0] REG_ID             = 'h00;
    localparam logic [AXI_ADDR_W-1:0] REG_VERSION        = 'h04;
    localparam logic [AXI_ADDR_W-1:0] REG_CONTROL        = 'h08;
    localparam logic [AXI_ADDR_W-1:0] REG_STATUS         = 'h0c;
    localparam logic [AXI_ADDR_W-1:0] REG_IRQ_ENABLE     = 'h10;
    localparam logic [AXI_ADDR_W-1:0] REG_IRQ_STATUS     = 'h14;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_ADDR   = 'h20;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_DATA_0 = 'h24;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_DATA_1 = 'h28;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_DATA_2 = 'h2c;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_DATA_3 = 'h30;
    localparam logic [AXI_ADDR_W-1:0] REG_PROGRAM_COMMIT = 'h34;
    localparam logic [AXI_ADDR_W-1:0] REG_DMA_CONFIG     = 'h40;
    localparam logic [AXI_ADDR_W-1:0] REG_DMA_LOCAL_ADDR = 'h44;
    localparam logic [AXI_ADDR_W-1:0] REG_DMA_EXT_ADDR   = 'h48;
    localparam logic [AXI_ADDR_W-1:0] REG_DMA_LENGTH     = 'h4c;
    localparam logic [AXI_ADDR_W-1:0] REG_DMA_SUBMIT     = 'h50;

    localparam logic [2:0] IRQ_COMPUTE_DONE = 3'b001;
    localparam logic [2:0] IRQ_DMA_DONE     = 3'b010;
    localparam logic [2:0] IRQ_FAULT        = 3'b100;

    logic aw_pending_q;
    logic [AXI_ADDR_W-1:0] awaddr_q;
    logic w_pending_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;

    logic [2:0] irq_enable_q;
    logic [2:0] irq_status_q;
    logic [31:0] program_addr_q;
    logic [31:0] program_data_q [0:3];
    logic [31:0] dma_config_q;
    logic [31:0] dma_local_addr_q;
    logic [31:0] dma_ext_addr_q;
    logic [31:0] dma_length_q;

    logic program_we;
    logic [PROGRAM_ADDR_W-1:0] program_addr;
    logic [127:0] program_wdata;
    logic start;
    logic compute_busy;
    logic compute_done;
    logic soc_fault;
    logic [3:0] soc_fault_code;

    logic dma_cmd_valid;
    logic dma_cmd_ready;
    logic dma_busy;
    logic dma_done;

    wire [2:0] irq_events =
        (compute_done ? IRQ_COMPUTE_DONE : 3'd0) |
        (dma_done ? IRQ_DMA_DONE : 3'd0) |
        (soc_fault ? IRQ_FAULT : 3'd0);
    wire [31:0] irq_enable_write_value = merge_wstrb(
        {29'd0, irq_enable_q}, wdata_q, wstrb_q
    );
    wire [31:0] status_value = {
        23'd0,
        dma_cmd_ready,
        soc_fault_code,
        irq,
        soc_fault,
        dma_busy,
        compute_busy
    };
    wire program_address_invalid = (program_addr_q >= IMEM_DEPTH);
    wire dma_local_address_invalid =
        ({32'd0, dma_local_addr_q} >= (64'd1 << ADDR_W));
    wire dma_external_address_invalid =
        ({32'd0, dma_ext_addr_q} >= (64'd1 << EXT_ADDR_W));
    wire dma_length_invalid = |dma_length_q[31:16];

    assign s_axi_awready = !aw_pending_q && !s_axi_bvalid;
    assign s_axi_wready  = !w_pending_q && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;
    assign irq = |(irq_enable_q & irq_status_q);

    assign program_addr = program_addr_q[PROGRAM_ADDR_W-1:0];
    assign program_wdata = {
        program_data_q[3],
        program_data_q[2],
        program_data_q[1],
        program_data_q[0]
    };

    function automatic [31:0] merge_wstrb(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0] byte_enable
    );
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (byte_enable[byte_index])
                    merge_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    systolicforge_soc #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH),
        .EXT_ADDR_W(EXT_ADDR_W)
    ) u_soc (
        .clk(clk),
        .rst_n(rst_n),
        .program_we(program_we),
        .program_addr(program_addr),
        .program_wdata(program_wdata),
        .start(start),
        .busy(compute_busy),
        .done(compute_done),
        .fault(soc_fault),
        .fault_code(soc_fault_code),
        .dma_cmd_valid(dma_cmd_valid),
        .dma_cmd_ready(dma_cmd_ready),
        .dma_cmd_to_local(dma_config_q[0]),
        .dma_cmd_mem(dma_config_q[2:1]),
        .dma_cmd_local_addr(dma_local_addr_q[ADDR_W-1:0]),
        .dma_cmd_ext_addr(dma_ext_addr_q[EXT_ADDR_W-1:0]),
        .dma_cmd_length(dma_length_q[15:0]),
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

    initial begin
        if (AXI_ADDR_W < 8)
            $error("AXI_ADDR_W must be at least 8");
        if ((ADDR_W > 32) || (EXT_ADDR_W > 32) || (PROGRAM_ADDR_W > 32))
            $error("AXI-Lite addressable fields must fit in 32-bit registers");
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending_q    <= 1'b0;
            awaddr_q        <= '0;
            w_pending_q     <= 1'b0;
            wdata_q         <= '0;
            wstrb_q         <= '0;
            s_axi_bresp     <= AXI_OKAY;
            s_axi_bvalid    <= 1'b0;
            s_axi_rdata     <= '0;
            s_axi_rresp     <= AXI_OKAY;
            s_axi_rvalid    <= 1'b0;
            irq_enable_q    <= '0;
            irq_status_q    <= '0;
            program_addr_q  <= '0;
            program_data_q[0] <= '0;
            program_data_q[1] <= '0;
            program_data_q[2] <= '0;
            program_data_q[3] <= '0;
            dma_config_q    <= '0;
            dma_local_addr_q <= '0;
            dma_ext_addr_q  <= '0;
            dma_length_q    <= '0;
            program_we      <= 1'b0;
            start           <= 1'b0;
            dma_cmd_valid   <= 1'b0;
        end else begin
            program_we    <= 1'b0;
            start         <= 1'b0;
            dma_cmd_valid <= 1'b0;
            irq_status_q  <= irq_status_q | irq_events;

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                aw_pending_q <= 1'b1;
                awaddr_q     <= s_axi_awaddr;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                w_pending_q <= 1'b1;
                wdata_q     <= s_axi_wdata;
                wstrb_q     <= s_axi_wstrb;
            end

            if (!s_axi_bvalid && aw_pending_q && w_pending_q) begin
                aw_pending_q <= 1'b0;
                w_pending_q  <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= AXI_OKAY;

                case (awaddr_q)
                    REG_ID,
                    REG_VERSION,
                    REG_STATUS: begin
                        s_axi_bresp <= AXI_SLVERR;
                    end

                    REG_CONTROL: begin
                        if (wstrb_q[0] && wdata_q[0]) begin
                            if (compute_busy || dma_busy)
                                s_axi_bresp <= AXI_SLVERR;
                            else
                                start <= 1'b1;
                        end
                    end

                    REG_IRQ_ENABLE: begin
                        irq_enable_q <= irq_enable_write_value[2:0];
                    end

                    REG_IRQ_STATUS: begin
                        if (wstrb_q[0])
                            irq_status_q <=
                                (irq_status_q & ~wdata_q[2:0]) | irq_events;
                    end

                    REG_PROGRAM_ADDR: begin
                        program_addr_q <= merge_wstrb(
                            program_addr_q, wdata_q, wstrb_q
                        );
                    end

                    REG_PROGRAM_DATA_0: begin
                        program_data_q[0] <= merge_wstrb(
                            program_data_q[0], wdata_q, wstrb_q
                        );
                    end

                    REG_PROGRAM_DATA_1: begin
                        program_data_q[1] <= merge_wstrb(
                            program_data_q[1], wdata_q, wstrb_q
                        );
                    end

                    REG_PROGRAM_DATA_2: begin
                        program_data_q[2] <= merge_wstrb(
                            program_data_q[2], wdata_q, wstrb_q
                        );
                    end

                    REG_PROGRAM_DATA_3: begin
                        program_data_q[3] <= merge_wstrb(
                            program_data_q[3], wdata_q, wstrb_q
                        );
                    end

                    REG_PROGRAM_COMMIT: begin
                        if (wstrb_q[0] && wdata_q[0]) begin
                            if (compute_busy || program_address_invalid)
                                s_axi_bresp <= AXI_SLVERR;
                            else
                                program_we <= 1'b1;
                        end
                    end

                    REG_DMA_CONFIG: begin
                        dma_config_q <= merge_wstrb(
                            dma_config_q, wdata_q, wstrb_q
                        );
                    end

                    REG_DMA_LOCAL_ADDR: begin
                        dma_local_addr_q <= merge_wstrb(
                            dma_local_addr_q, wdata_q, wstrb_q
                        );
                    end

                    REG_DMA_EXT_ADDR: begin
                        dma_ext_addr_q <= merge_wstrb(
                            dma_ext_addr_q, wdata_q, wstrb_q
                        );
                    end

                    REG_DMA_LENGTH: begin
                        dma_length_q <= merge_wstrb(
                            dma_length_q, wdata_q, wstrb_q
                        );
                    end

                    REG_DMA_SUBMIT: begin
                        if (wstrb_q[0] && wdata_q[0]) begin
                            if (!dma_cmd_ready ||
                                dma_local_address_invalid ||
                                dma_external_address_invalid ||
                                dma_length_invalid)
                                s_axi_bresp <= AXI_SLVERR;
                            else
                                dma_cmd_valid <= 1'b1;
                        end
                    end

                    default: begin
                        s_axi_bresp <= AXI_DECERR;
                    end
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= AXI_OKAY;

                case (s_axi_araddr)
                    REG_ID:             s_axi_rdata <= CORE_ID;
                    REG_VERSION:        s_axi_rdata <= CORE_VERSION;
                    REG_CONTROL:        s_axi_rdata <= 32'd0;
                    REG_STATUS:         s_axi_rdata <= status_value;
                    REG_IRQ_ENABLE:     s_axi_rdata <= {29'd0, irq_enable_q};
                    REG_IRQ_STATUS:     s_axi_rdata <= {29'd0, irq_status_q};
                    REG_PROGRAM_ADDR:   s_axi_rdata <= program_addr_q;
                    REG_PROGRAM_DATA_0: s_axi_rdata <= program_data_q[0];
                    REG_PROGRAM_DATA_1: s_axi_rdata <= program_data_q[1];
                    REG_PROGRAM_DATA_2: s_axi_rdata <= program_data_q[2];
                    REG_PROGRAM_DATA_3: s_axi_rdata <= program_data_q[3];
                    REG_PROGRAM_COMMIT: s_axi_rdata <= 32'd0;
                    REG_DMA_CONFIG:     s_axi_rdata <= dma_config_q;
                    REG_DMA_LOCAL_ADDR: s_axi_rdata <= dma_local_addr_q;
                    REG_DMA_EXT_ADDR:   s_axi_rdata <= dma_ext_addr_q;
                    REG_DMA_LENGTH:     s_axi_rdata <= dma_length_q;
                    REG_DMA_SUBMIT:     s_axi_rdata <= 32'd0;
                    default: begin
                        s_axi_rdata <= 32'd0;
                        s_axi_rresp <= AXI_DECERR;
                    end
                endcase
            end
        end
    end

    wire unused_protection =
        ^{s_axi_awprot, s_axi_arprot};

endmodule
