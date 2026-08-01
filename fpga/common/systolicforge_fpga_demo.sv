`timescale 1ns/1ps

module systolicforge_fpga_demo (
    input  logic        clk,
    input  logic        reset_button,
    input  logic        start_button,
    output logic [15:0] leds
);

    localparam integer ROWS = 8;
    localparam integer COLS = 8;
    localparam integer M    = 8;

    typedef enum logic [2:0] {
        DEMO_IDLE,
        DEMO_LOAD,
        DEMO_STREAM,
        DEMO_DRAIN,
        DEMO_DONE
    } demo_state_t;

    demo_state_t state_q;
    logic rst_n;
    logic start_meta;
    logic start_sync;
    logic start_prev;
    logic [3:0] issue_row_q;
    logic [3:0] capture_row_q [0:COLS-1];
    logic error_q;

    logic weight_load;
    logic input_valid;
    logic [ROWS*COLS*8-1:0] weights;
    logic [ROWS*8-1:0] activations;
    logic [COLS-1:0] output_valid;
    logic [COLS*32-1:0] results;

    integer lane_idx;
    integer capture_col;
    integer signed expected;

    function automatic signed [7:0] activation_value(
        input logic [3:0] matrix_row,
        input integer inner
    );
        integer signed value;
        begin
            value = matrix_row * ROWS + inner - 32;
            activation_value = value[7:0];
        end
    endfunction

    function automatic signed [7:0] diagonal_weight(input integer diagonal);
        begin
            case (diagonal)
                0: diagonal_weight =  1;
                1: diagonal_weight = -2;
                2: diagonal_weight =  3;
                3: diagonal_weight = -1;
                4: diagonal_weight =  2;
                5: diagonal_weight = -3;
                6: diagonal_weight =  1;
                default: diagonal_weight = -2;
            endcase
        end
    endfunction

    assign rst_n = !reset_button;
    assign weight_load = (state_q == DEMO_LOAD);
    assign input_valid = (state_q == DEMO_STREAM);

    genvar weight_row;
    genvar weight_col;
    generate
        for (weight_row = 0; weight_row < ROWS; weight_row = weight_row + 1) begin : g_demo_wrow
            for (weight_col = 0; weight_col < COLS; weight_col = weight_col + 1) begin : g_demo_wcol
                if (weight_row == weight_col) begin : g_diagonal
                    assign weights[((weight_row*COLS+weight_col)*8) +: 8] =
                        diagonal_weight(weight_row);
                end else begin : g_zero
                    assign weights[((weight_row*COLS+weight_col)*8) +: 8] = 8'sd0;
                end
            end
        end
    endgenerate

    always @* begin
        activations = '0;
        for (lane_idx = 0; lane_idx < ROWS; lane_idx = lane_idx + 1)
            activations[(lane_idx*8) +: 8] =
                activation_value(issue_row_q, lane_idx);
    end

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_W(8),
        .ACC_W(32)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .weight_load(weight_load),
        .weights(weights),
        .input_valid(input_valid),
        .activations(activations),
        .output_valid(output_valid),
        .results(results)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_meta <= 1'b0;
            start_sync <= 1'b0;
            start_prev <= 1'b0;
        end else begin
            start_meta <= start_button;
            start_sync <= start_meta;
            start_prev <= start_sync;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= DEMO_IDLE;
            issue_row_q <= '0;
            error_q     <= 1'b0;
            for (capture_col = 0; capture_col < COLS; capture_col = capture_col + 1)
                capture_row_q[capture_col] <= '0;
        end else begin
            case (state_q)
                DEMO_IDLE: begin
                    if (start_sync && !start_prev) begin
                        issue_row_q <= '0;
                        error_q <= 1'b0;
                        for (capture_col = 0; capture_col < COLS; capture_col = capture_col + 1)
                            capture_row_q[capture_col] <= '0;
                        state_q <= DEMO_LOAD;
                    end
                end

                DEMO_LOAD: state_q <= DEMO_STREAM;

                DEMO_STREAM: begin
                    if (issue_row_q == M-1)
                        state_q <= DEMO_DRAIN;
                    else
                        issue_row_q <= issue_row_q + 1'b1;
                end

                DEMO_DRAIN: begin end

                DEMO_DONE: begin
                    if (start_sync && !start_prev) begin
                        issue_row_q <= '0;
                        error_q <= 1'b0;
                        for (capture_col = 0; capture_col < COLS; capture_col = capture_col + 1)
                            capture_row_q[capture_col] <= '0;
                        state_q <= DEMO_LOAD;
                    end
                end

                default: state_q <= DEMO_IDLE;
            endcase

            if ((state_q == DEMO_STREAM) || (state_q == DEMO_DRAIN)) begin
                for (capture_col = 0; capture_col < COLS; capture_col = capture_col + 1) begin
                    if (output_valid[capture_col]) begin
                        expected =
                            activation_value(capture_row_q[capture_col], capture_col) *
                            diagonal_weight(capture_col);
                        if ($signed(results[(capture_col*32) +: 32]) != expected)
                            error_q <= 1'b1;
                        if ((capture_col == COLS-1) &&
                            (capture_row_q[capture_col] == M-1))
                            state_q <= DEMO_DONE;
                        capture_row_q[capture_col] <= capture_row_q[capture_col] + 1'b1;
                    end
                end
            end
        end
    end

    always @* begin
        leds = '0;
        leds[0] = (state_q == DEMO_DONE) && !error_q;
        leds[1] = (state_q == DEMO_DONE) && error_q;
        leds[2] = (state_q != DEMO_IDLE) && (state_q != DEMO_DONE);
        leds[6:3] = issue_row_q;
        leds[14:7] = output_valid;
        leds[15] = start_sync;
    end

endmodule
