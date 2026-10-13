`timescale 1ns/1ps

// Full-capacity engine with scheduled synchronous storage and one row in flight.
module systolicforge_npu #(
    parameter integer ARRAY_ROWS = 8, ARRAY_COLS = 8,
    parameter integer DATA_W = 8, ACC_W = 32, ADDR_W = 12,
    parameter integer IMEM_DEPTH = 256, INSTR_W = 128
) (
    input logic clk, rst_n,
    input logic program_we,
    input logic [$clog2(IMEM_DEPTH)-1:0] program_addr,
    input logic [INSTR_W-1:0] program_wdata,
    input logic dma_valid,
    output logic dma_ready,
    input logic dma_write,
    input logic [1:0] dma_mem,
    input logic [ADDR_W-1:0] dma_addr,
    input logic [ACC_W-1:0] dma_wdata,
    output logic [ACC_W-1:0] dma_rdata,
    input logic start,
    output logic busy, done, fault,
    output logic [3:0] fault_code,
    output logic [$clog2(IMEM_DEPTH)-1:0] pc_debug
);
    localparam integer DEPTH = (1 << ADDR_W);
    localparam integer TILE_WORDS = ARRAY_ROWS * ARRAY_COLS;
    localparam integer TILE_INDEX_W = (TILE_WORDS > 1) ? $clog2(TILE_WORDS) : 1;
    localparam integer LANE_INDEX_W = (ARRAY_ROWS > 1) ? $clog2(ARRAY_ROWS) : 1;
    localparam logic [3:0] FAULT_ILLEGAL_OPCODE = 4'h1;
    localparam logic [3:0] FAULT_ILLEGAL_DIMENSION = 4'h2;
    localparam logic [3:0] FAULT_ADDRESS_RANGE = 4'h3;
    localparam logic [3:0] FAULT_PROGRAM_OVERRUN = 4'h4;

    typedef enum logic [3:0] {
        ST_IDLE, ST_FETCH, ST_DECODE, ST_WEIGHT_REQ, ST_WEIGHT_CAPTURE,
        ST_LOAD_WEIGHTS, ST_ACT_REQ, ST_ACT_CAPTURE, ST_ISSUE, ST_DRAIN
    } state_t;
    state_t state_q;
    logic [$clog2(IMEM_DEPTH)-1:0] pc_q;
    logic [7:0] m_size_q, k_size_q, n_size_q, issue_row_q;
    logic [ADDR_W-1:0] a_base_q, b_base_q, c_base_q;
    logic [15:0] lda_q, ldb_q, ldc_q;
    logic accumulate_q;
    logic [TILE_INDEX_W-1:0] weight_index_q;
    logic [LANE_INDEX_W-1:0] activation_index_q;
    logic [DATA_W-1:0] weight_tile_q [0:TILE_WORDS-1];
    logic [DATA_W-1:0] activation_tile_q [0:ARRAY_ROWS-1];
    logic [INSTR_W-1:0] instruction;
    wire [7:0] instruction_m = instruction[15:8];
    wire [7:0] instruction_k = instruction[23:16];
    wire [7:0] instruction_n = instruction[31:24];
    logic [31:0] a_last_address, b_last_address, c_last_address;
    logic instruction_address_invalid;

    // A read response remains available while selector/address are held,
    // including external DMA backpressure. A new address invalidates ready.
    logic host_read_valid_q;
    logic [1:0] host_read_mem_q;
    logic [ADDR_W-1:0] host_read_addr_q;
    wire host_read_match = host_read_valid_q &&
        (dma_mem == host_read_mem_q) && (dma_addr == host_read_addr_q);
    wire host_read_request = rst_n && !busy && dma_valid && !dma_write &&
        !host_read_match;
    wire host_write = rst_n && dma_valid && dma_ready && dma_write;
    assign dma_ready = rst_n && !busy &&
        (!dma_valid || dma_write || host_read_match);

    logic [DATA_W-1:0] a_read_data, b_read_data;
    logic [ACC_W-1:0] c_read_data;
    logic [31:0] a_address_full, b_address_full;
    logic [ADDR_W-1:0] a_read_addr, b_read_addr, c_read_addr;
    wire active_weight = ((weight_index_q / ARRAY_COLS) < k_size_q) &&
                         ((weight_index_q % ARRAY_COLS) < n_size_q);
    wire active_activation = (activation_index_q < k_size_q);
    logic weight_load, array_input_valid;
    logic [ARRAY_ROWS*ARRAY_COLS*DATA_W-1:0] weight_bus;
    logic [ARRAY_ROWS*DATA_W-1:0] activation_bus;
    logic [ARRAY_COLS-1:0] array_output_valid;
    logic [ARRAY_COLS*ACC_W-1:0] array_results;
    logic capture_valid, capture_last;
    logic [31:0] capture_address_full;
    logic [ACC_W-1:0] capture_result;
    logic writeback_valid_q, writeback_last_q;
    logic [ADDR_W-1:0] writeback_addr_q;
    logic [ACC_W-1:0] writeback_result_q;
    logic c_write_enable;
    logic [ADDR_W-1:0] c_write_addr;
    logic [ACC_W-1:0] c_write_data;
    integer bus_index, capture_col;

    assign pc_debug = pc_q;
    assign weight_load = (state_q == ST_LOAD_WEIGHTS);
    assign array_input_valid = (state_q == ST_ISSUE);

    always @* begin
        a_last_address = {16'd0, instruction[47:32]} +
            ({24'd0, instruction_m} - 32'd1) * {16'd0, instruction[95:80]} +
            ({24'd0, instruction_k} - 32'd1);
        b_last_address = {16'd0, instruction[63:48]} +
            ({24'd0, instruction_k} - 32'd1) * {16'd0, instruction[111:96]} +
            ({24'd0, instruction_n} - 32'd1);
        c_last_address = {16'd0, instruction[79:64]} +
            ({24'd0, instruction_m} - 32'd1) * {16'd0, instruction[127:112]} +
            ({24'd0, instruction_n} - 32'd1);
        instruction_address_invalid = (a_last_address >= DEPTH) ||
            (b_last_address >= DEPTH) || (c_last_address >= DEPTH);
        a_address_full = 32'(a_base_q) + 32'(issue_row_q) * 32'(lda_q) +
                         32'(activation_index_q);
        b_address_full = 32'(b_base_q) + (32'(weight_index_q) / ARRAY_COLS) *
                         32'(ldb_q) + (32'(weight_index_q) % ARRAY_COLS);
        a_read_addr = busy ? a_address_full[ADDR_W-1:0] : dma_addr;
        b_read_addr = busy ? b_address_full[ADDR_W-1:0] : dma_addr;
        c_read_addr = busy ? capture_address_full[ADDR_W-1:0] : dma_addr;
        dma_rdata = '0;
        case (dma_mem)
            2'd0: dma_rdata = {{(ACC_W-DATA_W){a_read_data[DATA_W-1]}}, a_read_data};
            2'd1: dma_rdata = {{(ACC_W-DATA_W){b_read_data[DATA_W-1]}}, b_read_data};
            2'd2: dma_rdata = c_read_data;
            default: dma_rdata = '0;
        endcase
    end

    systolicforge_sdp_ram #(.DATA_W(INSTR_W), .ADDR_W($clog2(IMEM_DEPTH)),
                          .DEPTH(IMEM_DEPTH)) u_imem (
        .clk(clk), .write_enable(rst_n && program_we && !busy),
        .write_address(program_addr), .write_data(program_wdata),
        .read_enable(rst_n && (state_q == ST_FETCH)),
        .read_address(pc_q), .read_data(instruction)
    );
    systolicforge_sdp_ram #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_a (
        .clk(clk), .write_enable(host_write && (dma_mem == 2'd0)),
        .write_address(dma_addr), .write_data(dma_wdata[DATA_W-1:0]),
        .read_enable(rst_n && (((state_q == ST_ACT_REQ) && active_activation) ||
                     (host_read_request && (dma_mem == 2'd0)))),
        .read_address(a_read_addr), .read_data(a_read_data)
    );
    systolicforge_sdp_ram #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_b (
        .clk(clk), .write_enable(host_write && (dma_mem == 2'd1)),
        .write_address(dma_addr), .write_data(dma_wdata[DATA_W-1:0]),
        .read_enable(rst_n && (((state_q == ST_WEIGHT_REQ) && active_weight) ||
                     (host_read_request && (dma_mem == 2'd1)))),
        .read_address(b_read_addr), .read_data(b_read_data)
    );
    always @* begin
        c_write_enable = rst_n && (writeback_valid_q ||
                                  (host_write && (dma_mem == 2'd2)));
        c_write_addr = busy ? writeback_addr_q : dma_addr;
        c_write_data = busy ? (accumulate_q ? c_read_data + writeback_result_q :
                              writeback_result_q) : dma_wdata;
    end
    systolicforge_sdp_ram #(.DATA_W(ACC_W), .ADDR_W(ADDR_W)) u_c (
        .clk(clk), .write_enable(c_write_enable), .write_address(c_write_addr),
        .write_data(c_write_data),
        .read_enable(rst_n && ((capture_valid && accumulate_q) ||
                     (host_read_request && (dma_mem == 2'd2)))),
        .read_address(c_read_addr), .read_data(c_read_data)
    );

    always @* begin
        weight_bus = '0;
        activation_bus = '0;
        for (bus_index = 0; bus_index < TILE_WORDS; bus_index = bus_index + 1)
            weight_bus[bus_index*DATA_W +: DATA_W] = weight_tile_q[bus_index];
        for (bus_index = 0; bus_index < ARRAY_ROWS; bus_index = bus_index + 1)
            activation_bus[bus_index*DATA_W +: DATA_W] = activation_tile_q[bus_index];
        capture_valid = 1'b0;
        capture_last = 1'b0;
        capture_result = '0;
        capture_address_full = '0;
        // One row is in flight: its columns emerge on consecutive cycles.
        for (capture_col = 0; capture_col < ARRAY_COLS; capture_col = capture_col + 1) begin
            if ((state_q == ST_DRAIN) && array_output_valid[capture_col] &&
                (capture_col < n_size_q)) begin
                capture_valid = 1'b1;
                capture_last = (capture_col == n_size_q - 1'b1);
                capture_result = array_results[capture_col*ACC_W +: ACC_W];
                capture_address_full = 32'(c_base_q) + 32'(issue_row_q) *
                                       32'(ldc_q) + 32'(capture_col);
            end
        end
    end
    systolic_array #(.ROWS(ARRAY_ROWS), .COLS(ARRAY_COLS),
                    .DATA_W(DATA_W), .ACC_W(ACC_W)) u_array (
        .clk(clk), .rst_n(rst_n), .weight_load(weight_load), .weights(weight_bus),
        .input_valid(array_input_valid), .activations(activation_bus),
        .output_valid(array_output_valid), .results(array_results)
    );

    // Tile contents are overwritten before use; storage has no reset.
    always_ff @(posedge clk) begin
        if (state_q == ST_WEIGHT_CAPTURE)
            weight_tile_q[weight_index_q] <= active_weight ? b_read_data : '0;
        if (state_q == ST_ACT_CAPTURE)
            activation_tile_q[activation_index_q] <= active_activation ? a_read_data : '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_read_valid_q <= 1'b0;
            host_read_mem_q <= '0;
            host_read_addr_q <= '0;
        end else if (busy || !dma_valid || dma_write) begin
            host_read_valid_q <= 1'b0;
        end else if (host_read_request) begin
            host_read_valid_q <= 1'b1;
            host_read_mem_q <= dma_mem;
            host_read_addr_q <= dma_addr;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            pc_q <= '0;
            m_size_q <= '0;
            k_size_q <= '0;
            n_size_q <= '0;
            issue_row_q <= '0;
            a_base_q <= '0;
            b_base_q <= '0;
            c_base_q <= '0;
            lda_q <= '0;
            ldb_q <= '0;
            ldc_q <= '0;
            accumulate_q <= 1'b0;
            weight_index_q <= '0;
            activation_index_q <= '0;
            writeback_valid_q <= 1'b0;
            writeback_last_q <= 1'b0;
            writeback_addr_q <= '0;
            writeback_result_q <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            fault <= 1'b0;
            fault_code <= '0;
        end else begin
            done <= 1'b0;
            writeback_valid_q <= capture_valid;
            if (capture_valid) begin
                writeback_last_q <= capture_last;
                writeback_addr_q <= capture_address_full[ADDR_W-1:0];
                writeback_result_q <= capture_result;
            end
            case (state_q)
                ST_IDLE: if (start && !dma_valid) begin
                    pc_q <= '0;
                    busy <= 1'b1;
                    fault <= 1'b0;
                    fault_code <= '0;
                    state_q <= ST_FETCH;
                end
                ST_FETCH: state_q <= ST_DECODE;
                ST_DECODE: begin
                    case (instruction[3:0])
                        4'h0: if (pc_q == IMEM_DEPTH - 1) begin
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                            fault_code <= FAULT_PROGRAM_OVERRUN; state_q <= ST_IDLE;
                        end else begin pc_q <= pc_q + 1'b1; state_q <= ST_FETCH; end
                        4'h1: begin
                            if ((instruction_m == 0) || (instruction_k == 0) ||
                                (instruction_n == 0) || (instruction_k > ARRAY_ROWS) ||
                                (instruction_n > ARRAY_COLS)) begin
                                busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                                fault_code <= FAULT_ILLEGAL_DIMENSION; state_q <= ST_IDLE;
                            end else if (pc_q == IMEM_DEPTH - 1) begin
                                busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                                fault_code <= FAULT_PROGRAM_OVERRUN; state_q <= ST_IDLE;
                            end else if (instruction_address_invalid) begin
                                busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                                fault_code <= FAULT_ADDRESS_RANGE; state_q <= ST_IDLE;
                            end else begin
                                m_size_q <= instruction_m;
                                k_size_q <= instruction_k;
                                n_size_q <= instruction_n;
                                a_base_q <= ADDR_W'(instruction[47:32]);
                                b_base_q <= ADDR_W'(instruction[63:48]);
                                c_base_q <= ADDR_W'(instruction[79:64]);
                                lda_q <= instruction[95:80];
                                ldb_q <= instruction[111:96];
                                ldc_q <= instruction[127:112];
                                accumulate_q <= instruction[4];
                                issue_row_q <= '0;
                                weight_index_q <= '0;
                                state_q <= ST_WEIGHT_REQ;
                            end
                        end
                        4'hf: begin busy <= 1'b0; done <= 1'b1; state_q <= ST_IDLE; end
                        default: begin
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                            fault_code <= FAULT_ILLEGAL_OPCODE; state_q <= ST_IDLE;
                        end
                    endcase
                end
                ST_WEIGHT_REQ: state_q <= ST_WEIGHT_CAPTURE;
                ST_WEIGHT_CAPTURE: if (weight_index_q == TILE_WORDS - 1) begin
                    activation_index_q <= '0; state_q <= ST_LOAD_WEIGHTS;
                end else begin
                    weight_index_q <= weight_index_q + 1'b1; state_q <= ST_WEIGHT_REQ;
                end
                ST_LOAD_WEIGHTS: state_q <= ST_ACT_REQ;
                ST_ACT_REQ: state_q <= ST_ACT_CAPTURE;
                ST_ACT_CAPTURE: if (activation_index_q == ARRAY_ROWS - 1)
                    state_q <= ST_ISSUE;
                else begin
                    activation_index_q <= activation_index_q + 1'b1; state_q <= ST_ACT_REQ;
                end
                ST_ISSUE: state_q <= ST_DRAIN;
                ST_DRAIN: if (writeback_valid_q && writeback_last_q) begin
                    // This edge also commits C: release the row only afterward.
                    if (issue_row_q == m_size_q - 1'b1) begin
                        pc_q <= pc_q + 1'b1; state_q <= ST_FETCH;
                    end else begin
                        issue_row_q <= issue_row_q + 1'b1;
                        activation_index_q <= '0; state_q <= ST_ACT_REQ;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule
