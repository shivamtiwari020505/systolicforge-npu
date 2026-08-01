`timescale 1ns/1ps

module systolicforge_npu #(
    parameter integer ARRAY_ROWS    = 8,
    parameter integer ARRAY_COLS    = 8,
    parameter integer DATA_W        = 8,
    parameter integer ACC_W         = 32,
    parameter integer ADDR_W        = 12,
    parameter integer IMEM_DEPTH    = 256,
    parameter integer INSTR_W       = 128
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         program_we,
    input  logic [$clog2(IMEM_DEPTH)-1:0] program_addr,
    input  logic [INSTR_W-1:0]           program_wdata,

    input  logic                         dma_valid,
    output logic                         dma_ready,
    input  logic                         dma_write,
    input  logic [1:0]                   dma_mem,
    input  logic [ADDR_W-1:0]            dma_addr,
    input  logic [ACC_W-1:0]             dma_wdata,
    output logic [ACC_W-1:0]             dma_rdata,

    input  logic                         start,
    output logic                         busy,
    output logic                         done,
    output logic                         fault,
    output logic [$clog2(IMEM_DEPTH)-1:0] pc_debug
);

    localparam integer DEPTH = (1 << ADDR_W);
    localparam logic [3:0] OP_NOP    = 4'h0;
    localparam logic [3:0] OP_MATMUL = 4'h1;
    localparam logic [3:0] OP_HALT   = 4'hf;

    localparam logic [1:0] MEM_A = 2'd0;
    localparam logic [1:0] MEM_B = 2'd1;
    localparam logic [1:0] MEM_C = 2'd2;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_FETCH,
        ST_LOAD_WEIGHTS,
        ST_STREAM,
        ST_DRAIN
    } state_t;

    state_t state_q;

    logic signed [DATA_W-1:0] a_scratchpad [0:DEPTH-1];
    logic signed [DATA_W-1:0] b_scratchpad [0:DEPTH-1];
    logic signed [ACC_W-1:0]  c_scratchpad [0:DEPTH-1];
    logic [INSTR_W-1:0]       instruction_mem [0:IMEM_DEPTH-1];

    logic [$clog2(IMEM_DEPTH)-1:0] pc_q;
    wire [INSTR_W-1:0] instruction = instruction_mem[pc_q];

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

    logic weight_load;
    logic array_input_valid;
    logic [ARRAY_ROWS*ARRAY_COLS*DATA_W-1:0] weight_bus;
    logic [ARRAY_ROWS*DATA_W-1:0] activation_bus;
    logic [ARRAY_COLS-1:0] array_output_valid;
    logic [ARRAY_COLS*ACC_W-1:0] array_results;

    integer weight_row;
    integer weight_col;
    integer activation_lane;
    integer sequential_idx;
    integer capture_col;

    systolic_array #(
        .ROWS  (ARRAY_ROWS),
        .COLS  (ARRAY_COLS),
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) u_array (
        .clk         (clk),
        .rst_n       (rst_n),
        .weight_load (weight_load),
        .weights     (weight_bus),
        .input_valid (array_input_valid),
        .activations (activation_bus),
        .output_valid(array_output_valid),
        .results     (array_results)
    );

    assign pc_debug = pc_q;
    assign dma_ready = !busy;
    assign weight_load = (state_q == ST_LOAD_WEIGHTS);
    assign array_input_valid = (state_q == ST_STREAM);

    always @* begin
        dma_rdata = '0;
        case (dma_mem)
            MEM_A: dma_rdata = {{(ACC_W-DATA_W){a_scratchpad[dma_addr][DATA_W-1]}},
                                a_scratchpad[dma_addr]};
            MEM_B: dma_rdata = {{(ACC_W-DATA_W){b_scratchpad[dma_addr][DATA_W-1]}},
                                b_scratchpad[dma_addr]};
            MEM_C: dma_rdata = c_scratchpad[dma_addr];
            default: dma_rdata = '0;
        endcase
    end

    always @* begin
        weight_bus = '0;
        for (weight_row = 0; weight_row < ARRAY_ROWS; weight_row = weight_row + 1) begin
            for (weight_col = 0; weight_col < ARRAY_COLS; weight_col = weight_col + 1) begin
                if ((weight_row < k_size_q) && (weight_col < n_size_q)) begin
                    weight_bus[((weight_row*ARRAY_COLS+weight_col)*DATA_W) +: DATA_W] =
                        b_scratchpad[b_base_q + weight_row * ldb_q + weight_col];
                end
            end
        end
    end

    always @* begin
        activation_bus = '0;
        for (activation_lane = 0; activation_lane < ARRAY_ROWS;
             activation_lane = activation_lane + 1) begin
            if (activation_lane < k_size_q) begin
                activation_bus[(activation_lane*DATA_W) +: DATA_W] =
                    a_scratchpad[a_base_q + issue_row_q * lda_q + activation_lane];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= ST_IDLE;
            pc_q         <= '0;
            m_size_q     <= '0;
            k_size_q     <= '0;
            n_size_q     <= '0;
            a_base_q     <= '0;
            b_base_q     <= '0;
            c_base_q     <= '0;
            lda_q        <= '0;
            ldb_q        <= '0;
            ldc_q        <= '0;
            accumulate_q <= 1'b0;
            issue_row_q  <= '0;
            busy         <= 1'b0;
            done         <= 1'b0;
            fault        <= 1'b0;
            for (sequential_idx = 0; sequential_idx < ARRAY_COLS;
                 sequential_idx = sequential_idx + 1)
                capture_row_q[sequential_idx] <= '0;
        end else begin
            done <= 1'b0;

            if (program_we)
                instruction_mem[program_addr] <= program_wdata;

            if (dma_valid && dma_ready && dma_write) begin
                case (dma_mem)
                    MEM_A: a_scratchpad[dma_addr] <= dma_wdata[DATA_W-1:0];
                    MEM_B: b_scratchpad[dma_addr] <= dma_wdata[DATA_W-1:0];
                    MEM_C: c_scratchpad[dma_addr] <= dma_wdata;
                    default: begin end
                endcase
            end

            case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        pc_q  <= '0;
                        busy  <= 1'b1;
                        fault <= 1'b0;
                        state_q <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    case (instruction[3:0])
                        OP_NOP: pc_q <= pc_q + 1'b1;

                        OP_MATMUL: begin
                            if ((instruction[15:8] == 0) ||
                                (instruction[23:16] == 0) ||
                                (instruction[31:24] == 0) ||
                                (instruction[23:16] > ARRAY_ROWS) ||
                                (instruction[31:24] > ARRAY_COLS)) begin
                                busy    <= 1'b0;
                                done    <= 1'b1;
                                fault   <= 1'b1;
                                state_q <= ST_IDLE;
                            end else begin
                                accumulate_q <= instruction[4];
                                m_size_q     <= instruction[15:8];
                                k_size_q     <= instruction[23:16];
                                n_size_q     <= instruction[31:24];
                                a_base_q     <= instruction[32 +: ADDR_W];
                                b_base_q     <= instruction[48 +: ADDR_W];
                                c_base_q     <= instruction[64 +: ADDR_W];
                                lda_q        <= instruction[80 +: ADDR_W];
                                ldb_q        <= instruction[96 +: ADDR_W];
                                ldc_q        <= instruction[112 +: ADDR_W];
                                issue_row_q  <= '0;
                                for (sequential_idx = 0; sequential_idx < ARRAY_COLS;
                                     sequential_idx = sequential_idx + 1)
                                    capture_row_q[sequential_idx] <= '0;
                                state_q <= ST_LOAD_WEIGHTS;
                            end
                        end

                        OP_HALT: begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            state_q <= ST_IDLE;
                        end

                        default: begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            fault   <= 1'b1;
                            state_q <= ST_IDLE;
                        end
                    endcase
                end

                ST_LOAD_WEIGHTS: begin
                    state_q <= ST_STREAM;
                end

                ST_STREAM: begin
                    if (issue_row_q == m_size_q - 1'b1)
                        state_q <= ST_DRAIN;
                    else
                        issue_row_q <= issue_row_q + 1'b1;
                end

                ST_DRAIN: begin
                    // Completion is detected below as the last active column drains.
                end

                default: state_q <= ST_IDLE;
            endcase

            if ((state_q == ST_STREAM) || (state_q == ST_DRAIN)) begin
                for (capture_col = 0; capture_col < ARRAY_COLS;
                     capture_col = capture_col + 1) begin
                    if (array_output_valid[capture_col] && (capture_col < n_size_q)) begin
                        if (accumulate_q)
                            c_scratchpad[c_base_q + capture_row_q[capture_col] * ldc_q +
                                         capture_col] <=
                                c_scratchpad[c_base_q + capture_row_q[capture_col] * ldc_q +
                                             capture_col] +
                                $signed(array_results[(capture_col*ACC_W) +: ACC_W]);
                        else
                            c_scratchpad[c_base_q + capture_row_q[capture_col] * ldc_q +
                                         capture_col] <=
                                $signed(array_results[(capture_col*ACC_W) +: ACC_W]);

                        if ((capture_col == n_size_q - 1'b1) &&
                            (capture_row_q[capture_col] == m_size_q - 1'b1)) begin
                            pc_q    <= pc_q + 1'b1;
                            state_q <= ST_FETCH;
                        end
                        capture_row_q[capture_col] <= capture_row_q[capture_col] + 1'b1;
                    end
                end
            end
        end
    end

endmodule
