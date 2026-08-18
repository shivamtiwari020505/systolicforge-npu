`timescale 1ns/1ps

module scratchpad_dma #(
    parameter integer LOCAL_ADDR_W = 12,
    parameter integer EXT_ADDR_W   = 32,
    parameter integer DATA_W       = 32,
    parameter integer LEN_W        = 16
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     cmd_valid,
    output logic                     cmd_ready,
    input  logic                     cmd_to_local,
    input  logic [1:0]               cmd_mem,
    input  logic [LOCAL_ADDR_W-1:0]  cmd_local_addr,
    input  logic [EXT_ADDR_W-1:0]    cmd_ext_addr,
    input  logic [LEN_W-1:0]         cmd_length,
    output logic                     busy,
    output logic                     done,
    output logic                     fault,
    output logic [3:0]               fault_code,

    output logic                     local_valid,
    input  logic                     local_ready,
    output logic                     local_write,
    output logic [1:0]               local_mem,
    output logic [LOCAL_ADDR_W-1:0]  local_addr,
    output logic [DATA_W-1:0]        local_wdata,
    input  logic [DATA_W-1:0]        local_rdata,

    output logic                     ext_req_valid,
    input  logic                     ext_req_ready,
    output logic                     ext_req_write,
    output logic [EXT_ADDR_W-1:0]    ext_req_addr,
    output logic [DATA_W-1:0]        ext_req_wdata,
    input  logic                     ext_rsp_valid,
    input  logic [DATA_W-1:0]        ext_rsp_rdata
);

    localparam integer BYTES_PER_WORD = DATA_W/8;
    localparam logic [EXT_ADDR_W-1:0] ADDRESS_INCREMENT =
        EXT_ADDR_W'(BYTES_PER_WORD);
    localparam logic [1:0] MEM_C = 2'd2;
    localparam logic [3:0] FAULT_NONE                 = 4'h0;
    localparam logic [3:0] FAULT_DMA_INVALID_MEMORY   = 4'h5;
    localparam logic [3:0] FAULT_DMA_LOCAL_RANGE      = 4'h6;
    localparam logic [3:0] FAULT_DMA_EXTERNAL_ADDRESS = 4'h7;

    typedef enum logic [1:0] {
        DMA_IDLE,
        DMA_LOAD_REQ,
        DMA_LOAD_WAIT,
        DMA_STORE_REQ
    } dma_state_t;

    dma_state_t state_q;
    logic [1:0] mem_q;
    logic [LOCAL_ADDR_W-1:0] local_addr_q;
    logic [EXT_ADDR_W-1:0] ext_addr_q;
    logic [LEN_W-1:0] remaining_q;

    wire [63:0] cmd_local_extended =
        {{(64-LOCAL_ADDR_W){1'b0}}, cmd_local_addr};
    wire [63:0] cmd_ext_extended =
        {{(64-EXT_ADDR_W){1'b0}}, cmd_ext_addr};
    wire [63:0] cmd_length_extended =
        {{(64-LEN_W){1'b0}}, cmd_length};
    wire [63:0] local_limit = 64'd1 << LOCAL_ADDR_W;
    wire [63:0] external_limit = 64'd1 << EXT_ADDR_W;
    wire [63:0] local_end = cmd_local_extended + cmd_length_extended;
    wire [63:0] external_end = cmd_ext_extended +
                               cmd_length_extended * BYTES_PER_WORD;
    wire local_range_invalid = (cmd_length != 0) &&
                               (local_end > local_limit);
    wire external_address_invalid = (cmd_length != 0) &&
                                    ((external_end > external_limit) ||
                                     ((cmd_ext_addr % BYTES_PER_WORD) != 0));

    assign cmd_ready = (state_q == DMA_IDLE) && local_ready;
    assign busy = (state_q != DMA_IDLE);

    always @* begin
        local_valid   = 1'b0;
        local_write   = 1'b0;
        local_mem     = mem_q;
        local_addr    = local_addr_q;
        local_wdata   = ext_rsp_rdata;
        ext_req_valid = 1'b0;
        ext_req_write = 1'b0;
        ext_req_addr  = ext_addr_q;
        ext_req_wdata = local_rdata;

        case (state_q)
            DMA_LOAD_REQ: begin
                ext_req_valid = 1'b1;
                ext_req_write = 1'b0;
            end
            DMA_LOAD_WAIT: begin
                local_valid = ext_rsp_valid;
                local_write = 1'b1;
            end
            DMA_STORE_REQ: begin
                local_valid   = 1'b1;
                local_write   = 1'b0;
                ext_req_valid = local_ready;
                ext_req_write = 1'b1;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= DMA_IDLE;
            mem_q        <= '0;
            local_addr_q <= '0;
            ext_addr_q   <= '0;
            remaining_q  <= '0;
            done         <= 1'b0;
            fault        <= 1'b0;
            fault_code   <= FAULT_NONE;
        end else begin
            done <= 1'b0;

            case (state_q)
                DMA_IDLE: begin
                    if (cmd_valid && cmd_ready) begin
                        fault      <= 1'b0;
                        fault_code <= FAULT_NONE;
                        if (cmd_mem > MEM_C) begin
                            done       <= 1'b1;
                            fault      <= 1'b1;
                            fault_code <= FAULT_DMA_INVALID_MEMORY;
                        end else if (cmd_length == 0) begin
                            done <= 1'b1;
                        end else if (local_range_invalid) begin
                            done       <= 1'b1;
                            fault      <= 1'b1;
                            fault_code <= FAULT_DMA_LOCAL_RANGE;
                        end else if (external_address_invalid) begin
                            done       <= 1'b1;
                            fault      <= 1'b1;
                            fault_code <= FAULT_DMA_EXTERNAL_ADDRESS;
                        end else begin
                            mem_q        <= cmd_mem;
                            local_addr_q <= cmd_local_addr;
                            ext_addr_q   <= cmd_ext_addr;
                            remaining_q  <= cmd_length;
                            state_q <= cmd_to_local ? DMA_LOAD_REQ : DMA_STORE_REQ;
                        end
                    end
                end

                DMA_LOAD_REQ: begin
                    if (ext_req_valid && ext_req_ready)
                        state_q <= DMA_LOAD_WAIT;
                end

                DMA_LOAD_WAIT: begin
                    if (ext_rsp_valid && local_ready) begin
                        if (remaining_q == 1) begin
                            remaining_q <= '0;
                            state_q     <= DMA_IDLE;
                            done        <= 1'b1;
                        end else begin
                            remaining_q  <= remaining_q - 1'b1;
                            local_addr_q <= local_addr_q + 1'b1;
                            ext_addr_q   <= ext_addr_q + ADDRESS_INCREMENT;
                            state_q      <= DMA_LOAD_REQ;
                        end
                    end
                end

                DMA_STORE_REQ: begin
                    if (local_ready && ext_req_valid && ext_req_ready) begin
                        if (remaining_q == 1) begin
                            remaining_q <= '0;
                            state_q     <= DMA_IDLE;
                            done        <= 1'b1;
                        end else begin
                            remaining_q  <= remaining_q - 1'b1;
                            local_addr_q <= local_addr_q + 1'b1;
                            ext_addr_q   <= ext_addr_q + ADDRESS_INCREMENT;
                        end
                    end
                end

                default: state_q <= DMA_IDLE;
            endcase
        end
    end

endmodule
