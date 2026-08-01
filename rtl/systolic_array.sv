`timescale 1ns/1ps

module systolic_array #(
    parameter integer ROWS   = 8,
    parameter integer COLS   = 8,
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         weight_load,
    input  logic [ROWS*COLS*DATA_W-1:0]  weights,
    input  logic                         input_valid,
    input  logic [ROWS*DATA_W-1:0]       activations,
    output logic [COLS-1:0]              output_valid,
    output logic [COLS*ACC_W-1:0]        results
);

    logic signed [DATA_W-1:0] row_skew_data [0:ROWS-1][0:ROWS-1];
    logic                     row_skew_valid[0:ROWS-1][0:ROWS-1];

    wire signed [DATA_W-1:0] activation_bus [0:ROWS-1][0:COLS];
    wire                     activation_vld [0:ROWS-1][0:COLS];
    wire signed [ACC_W-1:0]  psum_bus       [0:ROWS][0:COLS-1];
    wire                     psum_vld       [0:ROWS][0:COLS-1];

    genvar r;
    genvar c;

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_row_inputs
            if (r == 0) begin : g_unskewed
                assign activation_bus[r][0] =
                    $signed(activations[(r*DATA_W) +: DATA_W]);
                assign activation_vld[r][0] = input_valid;
            end else begin : g_skewed
                assign activation_bus[r][0] = row_skew_data[r][r-1];
                assign activation_vld[r][0] = row_skew_valid[r][r-1];
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin : g_top_psum
            assign psum_bus[0][c] = '0;
            assign psum_vld[0][c] = 1'b1;
        end

        for (r = 0; r < ROWS; r = r + 1) begin : g_pe_rows
            for (c = 0; c < COLS; c = c + 1) begin : g_pe_cols
                systolic_pe #(
                    .DATA_W(DATA_W),
                    .ACC_W (ACC_W),
                    .TOP_ROW(r == 0)
                ) u_pe (
                    .clk                 (clk),
                    .rst_n               (rst_n),
                    .weight_load         (weight_load),
                    .weight_in           ($signed(weights[((r*COLS+c)*DATA_W) +: DATA_W])),
                    .activation_in       (activation_bus[r][c]),
                    .activation_valid_in (activation_vld[r][c]),
                    .psum_in             (psum_bus[r][c]),
                    .psum_valid_in       (psum_vld[r][c]),
                    .activation_out      (activation_bus[r][c+1]),
                    .activation_valid_out(activation_vld[r][c+1]),
                    .psum_out            (psum_bus[r+1][c]),
                    .psum_valid_out      (psum_vld[r+1][c])
                );
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin : g_outputs
            assign output_valid[c] = psum_vld[ROWS][c];
            assign results[(c*ACC_W) +: ACC_W] = psum_bus[ROWS][c];
        end
    endgenerate

    integer row_idx;
    integer delay_idx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (row_idx = 0; row_idx < ROWS; row_idx = row_idx + 1) begin
                for (delay_idx = 0; delay_idx < ROWS; delay_idx = delay_idx + 1) begin
                    row_skew_data[row_idx][delay_idx]  <= '0;
                    row_skew_valid[row_idx][delay_idx] <= 1'b0;
                end
            end
        end else begin
            for (row_idx = 1; row_idx < ROWS; row_idx = row_idx + 1) begin
                row_skew_data[row_idx][0] <=
                    $signed(activations[(row_idx*DATA_W) +: DATA_W]);
                row_skew_valid[row_idx][0] <= input_valid;
                for (delay_idx = 1; delay_idx < ROWS; delay_idx = delay_idx + 1) begin
                    if (delay_idx < row_idx) begin
                        row_skew_data[row_idx][delay_idx] <=
                            row_skew_data[row_idx][delay_idx-1];
                        row_skew_valid[row_idx][delay_idx] <=
                            row_skew_valid[row_idx][delay_idx-1];
                    end
                end
            end
        end
    end

endmodule
