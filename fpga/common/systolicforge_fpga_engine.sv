`timescale 1ns/1ps

// FPGA-oriented execution engine for the Basys3 demonstration.
//
// It implements the same NOP/MATMUL/HALT instruction fields and programming /
// scratchpad ports as systolicforge_npu. Unlike the throughput-oriented NPU,
// this engine serializes scratchpad reads into small tile registers so A/B/C
// infer as single-read-port memories instead of large asynchronous multi-port
// mux networks. One activation row is issued every ARRAY_ROWS+1 cycles.
module systolicforge_fpga_engine #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 8,
    parameter integer DATA_W     = 8,
    parameter integer ACC_W      = 32,
    parameter integer ADDR_W     = 7,
    parameter integer IMEM_DEPTH = 16,
    parameter integer INSTR_W    = 128
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          program_we,
    input  logic [$clog2(IMEM_DEPTH)-1:0] program_addr,
    input  logic [INSTR_W-1:0]            program_wdata,

    input  logic                          dma_valid,
    output logic                          dma_ready,
    input  logic                          dma_write,
    input  logic [1:0]                    dma_mem,
    input  logic [ADDR_W-1:0]             dma_addr,
    input  logic [ACC_W-1:0]              dma_wdata,
    output logic [ACC_W-1:0]              dma_rdata,

    input  logic                          start,
    output logic                          busy,
    output logic                          done,
    output logic                          fault,
    output logic [3:0]                    fault_code,
    output logic [$clog2(IMEM_DEPTH)-1:0] pc_debug
);

    localparam integer DEPTH = (1 << ADDR_W);
    localparam integer TILE_WORDS = ARRAY_ROWS * ARRAY_COLS;
    localparam integer TILE_INDEX_W = $clog2(TILE_WORDS);
    localparam integer ROW_INDEX_W = $clog2(ARRAY_ROWS);
    localparam integer COLUMN_INDEX_W = $clog2(ARRAY_COLS);

    localparam logic [3:0] OP_NOP    = 4'h0;
    localparam logic [3:0] OP_MATMUL = 4'h1;
    localparam logic [3:0] OP_HALT   = 4'hf;

    localparam logic [3:0] FAULT_NONE              = 4'h0;
    localparam logic [3:0] FAULT_ILLEGAL_OPCODE    = 4'h1;
    localparam logic [3:0] FAULT_ILLEGAL_DIMENSION = 4'h2;
    localparam logic [3:0] FAULT_ADDRESS_RANGE     = 4'h3;
    localparam logic [3:0] FAULT_PROGRAM_OVERRUN   = 4'h4;

    localparam logic [1:0] MEM_A = 2'd0;
    localparam logic [1:0] MEM_B = 2'd1;
    localparam logic [1:0] MEM_C = 2'd2;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_FETCH,
        ST_PREFETCH_WEIGHTS,
        ST_LOAD_WEIGHTS,
        ST_PREFETCH_ACTIVATIONS,
        ST_ISSUE,
        ST_DRAIN
    } state_t;

    state_t state_q;

    // These memories intentionally use asynchronous reads and synchronous,
    // non-reset writes so Vivado can implement them as distributed RAM. Keep
    // their writes out of the asynchronously reset control process below.
    (* ram_style = "distributed" *)
    logic signed [DATA_W-1:0] a_scratchpad [0:DEPTH-1];
    (* ram_style = "distributed" *)
    logic signed [DATA_W-1:0] b_scratchpad [0:DEPTH-1];
    (* ram_style = "distributed" *)
    logic signed [ACC_W-1:0] c_scratchpad [0:DEPTH-1];
    (* ram_style = "distributed" *)
    logic [INSTR_W-1:0] instruction_mem [0:IMEM_DEPTH-1];

    logic signed [DATA_W-1:0] weight_tile_q [0:TILE_WORDS-1];
    logic signed [DATA_W-1:0] activation_tile_q [0:ARRAY_ROWS-1];

    logic [$clog2(IMEM_DEPTH)-1:0] pc_q;
    logic [7:0] m_size_q;
    logic [7:0] k_size_q;
    logic [7:0] n_size_q;
    logic [ADDR_W-1:0] a_base_q;
    logic [ADDR_W-1:0] b_base_q;
    logic [ADDR_W-1:0] c_base_q;
    logic [ADDR_W-1:0] lda_q;
    logic [ADDR_W-1:0] ldb_q;
    logic [ADDR_W-1:0] ldc_q;
    logic accumulate_q;
    logic [7:0] issue_row_q;
    logic [7:0] capture_row_q [0:ARRAY_COLS-1];
    logic [TILE_INDEX_W-1:0] weight_index_q;
    logic [ROW_INDEX_W-1:0] activation_index_q;

    wire [INSTR_W-1:0] instruction = instruction_mem[pc_q];
    wire [7:0] instruction_m = instruction[15:8];
    wire [7:0] instruction_k = instruction[23:16];
    wire [7:0] instruction_n = instruction[31:24];
    wire [15:0] instruction_a_base = instruction[47:32];
    wire [15:0] instruction_b_base = instruction[63:48];
    wire [15:0] instruction_c_base = instruction[79:64];
    wire [15:0] instruction_lda = instruction[95:80];
    wire [15:0] instruction_ldb = instruction[111:96];
    wire [15:0] instruction_ldc = instruction[127:112];

    logic [31:0] a_last_address;
    logic [31:0] b_last_address;
    logic [31:0] c_last_address;
    logic instruction_address_invalid;
    logic pc_at_last_word;

    logic [ADDR_W-1:0] a_read_addr;
    logic [ADDR_W-1:0] b_read_addr;
    logic [ADDR_W-1:0] c_read_addr;
    logic [31:0] a_internal_address;
    logic [31:0] b_internal_address;
    logic signed [DATA_W-1:0] a_read_data;
    logic signed [DATA_W-1:0] b_read_data;
    logic signed [ACC_W-1:0] c_read_data;

    logic weight_load;
    logic array_input_valid;
    logic [ARRAY_ROWS*ARRAY_COLS*DATA_W-1:0] weight_bus;
    logic [ARRAY_ROWS*DATA_W-1:0] activation_bus;
    logic [ARRAY_COLS-1:0] array_output_valid;
    logic [ARRAY_COLS*ACC_W-1:0] array_results;

    logic capture_valid;
    logic [COLUMN_INDEX_W-1:0] capture_column;
    logic [ADDR_W-1:0] capture_address;
    logic [31:0] capture_address_full;
    logic signed [ACC_W-1:0] capture_result;
    logic capture_is_last;

    logic c_write_enable;
    logic [ADDR_W-1:0] c_write_addr;
    logic signed [ACC_W-1:0] c_write_data;

    integer bus_index;
    integer capture_scan;
    integer sequential_idx;

    assign pc_debug = pc_q;
    assign dma_ready = !busy;
    assign weight_load = (state_q == ST_LOAD_WEIGHTS);
    assign array_input_valid = (state_q == ST_ISSUE);

    always @* begin
        a_last_address = {16'd0, instruction_a_base} +
                         ({24'd0, instruction_m} - 32'd1) *
                         {16'd0, instruction_lda} +
                         ({24'd0, instruction_k} - 32'd1);
        b_last_address = {16'd0, instruction_b_base} +
                         ({24'd0, instruction_k} - 32'd1) *
                         {16'd0, instruction_ldb} +
                         ({24'd0, instruction_n} - 32'd1);
        c_last_address = {16'd0, instruction_c_base} +
                         ({24'd0, instruction_m} - 32'd1) *
                         {16'd0, instruction_ldc} +
                         ({24'd0, instruction_n} - 32'd1);
        instruction_address_invalid = (a_last_address >= DEPTH) ||
                                      (b_last_address >= DEPTH) ||
                                      (c_last_address >= DEPTH);
        pc_at_last_word = (pc_q == IMEM_DEPTH - 1);
    end

    // Compute and host accesses are mutually exclusive, so each scratchpad has
    // one selected read address. This is important for LUTRAM inference.
    always @* begin
        a_internal_address = {{(32-ADDR_W){1'b0}}, a_base_q} +
                             issue_row_q * {{(32-ADDR_W){1'b0}}, lda_q} +
                             activation_index_q;
        b_internal_address = {{(32-ADDR_W){1'b0}}, b_base_q} +
                             (weight_index_q / ARRAY_COLS) *
                             {{(32-ADDR_W){1'b0}}, ldb_q} +
                             (weight_index_q % ARRAY_COLS);

        a_read_addr = dma_addr;
        b_read_addr = dma_addr;
        c_read_addr = dma_addr;

        if (state_q == ST_PREFETCH_ACTIVATIONS)
            a_read_addr = a_internal_address[ADDR_W-1:0];
        if (state_q == ST_PREFETCH_WEIGHTS)
            b_read_addr = b_internal_address[ADDR_W-1:0];
        if (capture_valid)
            c_read_addr = capture_address;
    end

    assign a_read_data = a_scratchpad[a_read_addr];
    assign b_read_data = b_scratchpad[b_read_addr];
    assign c_read_data = c_scratchpad[c_read_addr];

    always @* begin
        dma_rdata = '0;
        case (dma_mem)
            MEM_A: dma_rdata = {{(ACC_W-DATA_W){a_read_data[DATA_W-1]}},
                                a_read_data};
            MEM_B: dma_rdata = {{(ACC_W-DATA_W){b_read_data[DATA_W-1]}},
                                b_read_data};
            MEM_C: dma_rdata = c_read_data;
            default: dma_rdata = '0;
        endcase
    end

    // The host and compute engine are mutually exclusive, so C has one
    // physical write port. Expressing that port explicitly avoids Vivado
    // dissolving the complete C scratchpad into registers and a deep mux.
    always @* begin
        c_write_enable = 1'b0;
        c_write_addr = '0;
        c_write_data = '0;

        if (dma_valid && dma_ready && dma_write && (dma_mem == MEM_C)) begin
            c_write_enable = 1'b1;
            c_write_addr = dma_addr;
            c_write_data = dma_wdata;
        end else if (capture_valid) begin
            c_write_enable = 1'b1;
            c_write_addr = capture_address;
            if (accumulate_q)
                c_write_data = c_read_data + capture_result;
            else
                c_write_data = capture_result;
        end
    end

    always @* begin
        weight_bus = '0;
        for (bus_index = 0; bus_index < TILE_WORDS; bus_index = bus_index + 1)
            weight_bus[(bus_index*DATA_W) +: DATA_W] = weight_tile_q[bus_index];

        activation_bus = '0;
        for (bus_index = 0; bus_index < ARRAY_ROWS; bus_index = bus_index + 1)
            activation_bus[(bus_index*DATA_W) +: DATA_W] = activation_tile_q[bus_index];
    end

    // Rows are issued ARRAY_ROWS+1 cycles apart, so at most one active output
    // column arrives in a cycle. Collapse the per-column bus to one C write.
    always @* begin
        capture_valid = 1'b0;
        capture_column = '0;
        capture_address_full = '0;
        capture_result = '0;
        capture_is_last = 1'b0;

        for (capture_scan = 0; capture_scan < ARRAY_COLS;
             capture_scan = capture_scan + 1) begin
            if (!capture_valid && array_output_valid[capture_scan] &&
                (capture_scan < n_size_q)) begin
                capture_valid = 1'b1;
                capture_column = capture_scan[COLUMN_INDEX_W-1:0];
                capture_address_full = {{(32-ADDR_W){1'b0}}, c_base_q} +
                                       capture_row_q[capture_scan] *
                                       {{(32-ADDR_W){1'b0}}, ldc_q} +
                                       capture_scan;
                capture_result = $signed(
                    array_results[(capture_scan*ACC_W) +: ACC_W]
                );
                capture_is_last =
                    (capture_scan == n_size_q - 1'b1) &&
                    (capture_row_q[capture_scan] == m_size_q - 1'b1);
            end
        end
        capture_address = capture_address_full[ADDR_W-1:0];
    end

    systolic_array #(
        .ROWS(ARRAY_ROWS),
        .COLS(ARRAY_COLS),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .weight_load(weight_load),
        .weights(weight_bus),
        .input_valid(array_input_valid),
        .activations(activation_bus),
        .output_valid(array_output_valid),
        .results(array_results)
    );

    // Memory and tile-storage writes deliberately have no asynchronous reset.
    // Every location is initialized by the host or prefetch state before use.
    // This coding style is required for FPGA RAM inference.
    always_ff @(posedge clk) begin
        if (program_we)
            instruction_mem[program_addr] <= program_wdata;

        if (dma_valid && dma_ready && dma_write) begin
            case (dma_mem)
                MEM_A: a_scratchpad[dma_addr] <= dma_wdata[DATA_W-1:0];
                MEM_B: b_scratchpad[dma_addr] <= dma_wdata[DATA_W-1:0];
                default: begin end
            endcase
        end

        if (c_write_enable)
            c_scratchpad[c_write_addr] <= c_write_data;

        if (state_q == ST_PREFETCH_WEIGHTS) begin
            if (((weight_index_q / ARRAY_COLS) < k_size_q) &&
                ((weight_index_q % ARRAY_COLS) < n_size_q))
                weight_tile_q[weight_index_q] <= b_read_data;
            else
                weight_tile_q[weight_index_q] <= '0;
        end

        if (state_q == ST_PREFETCH_ACTIVATIONS) begin
            if (activation_index_q < k_size_q)
                activation_tile_q[activation_index_q] <= a_read_data;
            else
                activation_tile_q[activation_index_q] <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            pc_q <= '0;
            m_size_q <= '0;
            k_size_q <= '0;
            n_size_q <= '0;
            a_base_q <= '0;
            b_base_q <= '0;
            c_base_q <= '0;
            lda_q <= '0;
            ldb_q <= '0;
            ldc_q <= '0;
            accumulate_q <= 1'b0;
            issue_row_q <= '0;
            weight_index_q <= '0;
            activation_index_q <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            fault <= 1'b0;
            fault_code <= FAULT_NONE;
            for (sequential_idx = 0; sequential_idx < ARRAY_COLS;
                 sequential_idx = sequential_idx + 1)
                capture_row_q[sequential_idx] <= '0;
        end else begin
            done <= 1'b0;

            if (capture_valid)
                capture_row_q[capture_column] <=
                    capture_row_q[capture_column] + 1'b1;

            case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        pc_q <= '0;
                        busy <= 1'b1;
                        fault <= 1'b0;
                        fault_code <= FAULT_NONE;
                        state_q <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    case (instruction[3:0])
                        OP_NOP: begin
                            if (pc_at_last_word) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_code <= FAULT_PROGRAM_OVERRUN;
                                state_q <= ST_IDLE;
                            end else begin
                                pc_q <= pc_q + 1'b1;
                            end
                        end

                        OP_MATMUL: begin
                            if ((instruction_m == 0) ||
                                (instruction_k == 0) ||
                                (instruction_n == 0) ||
                                (instruction_k > ARRAY_ROWS) ||
                                (instruction_n > ARRAY_COLS)) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_code <= FAULT_ILLEGAL_DIMENSION;
                                state_q <= ST_IDLE;
                            end else if (pc_at_last_word) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_code <= FAULT_PROGRAM_OVERRUN;
                                state_q <= ST_IDLE;
                            end else if (instruction_address_invalid) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                fault <= 1'b1;
                                fault_code <= FAULT_ADDRESS_RANGE;
                                state_q <= ST_IDLE;
                            end else begin
                                accumulate_q <= instruction[4];
                                m_size_q <= instruction_m;
                                k_size_q <= instruction_k;
                                n_size_q <= instruction_n;
                                a_base_q <= instruction[32 +: ADDR_W];
                                b_base_q <= instruction[48 +: ADDR_W];
                                c_base_q <= instruction[64 +: ADDR_W];
                                lda_q <= instruction[80 +: ADDR_W];
                                ldb_q <= instruction[96 +: ADDR_W];
                                ldc_q <= instruction[112 +: ADDR_W];
                                issue_row_q <= '0;
                                weight_index_q <= '0;
                                for (sequential_idx = 0; sequential_idx < ARRAY_COLS;
                                     sequential_idx = sequential_idx + 1)
                                    capture_row_q[sequential_idx] <= '0;
                                state_q <= ST_PREFETCH_WEIGHTS;
                            end
                        end

                        OP_HALT: begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state_q <= ST_IDLE;
                        end

                        default: begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            fault <= 1'b1;
                            fault_code <= FAULT_ILLEGAL_OPCODE;
                            state_q <= ST_IDLE;
                        end
                    endcase
                end

                ST_PREFETCH_WEIGHTS: begin
                    if (weight_index_q == TILE_WORDS - 1) begin
                        weight_index_q <= '0;
                        state_q <= ST_LOAD_WEIGHTS;
                    end else begin
                        weight_index_q <= weight_index_q + 1'b1;
                    end
                end

                ST_LOAD_WEIGHTS: begin
                    activation_index_q <= '0;
                    state_q <= ST_PREFETCH_ACTIVATIONS;
                end

                ST_PREFETCH_ACTIVATIONS: begin
                    if (activation_index_q == ARRAY_ROWS - 1) begin
                        activation_index_q <= '0;
                        state_q <= ST_ISSUE;
                    end else begin
                        activation_index_q <= activation_index_q + 1'b1;
                    end
                end

                ST_ISSUE: begin
                    if (issue_row_q == m_size_q - 1'b1) begin
                        state_q <= ST_DRAIN;
                    end else begin
                        issue_row_q <= issue_row_q + 1'b1;
                        activation_index_q <= '0;
                        state_q <= ST_PREFETCH_ACTIVATIONS;
                    end
                end

                ST_DRAIN: begin
                    if (capture_valid && capture_is_last) begin
                        pc_q <= pc_q + 1'b1;
                        state_q <= ST_FETCH;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
