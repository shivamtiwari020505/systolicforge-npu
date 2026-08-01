`timescale 1ns/1ps

// Narrow-pin implementation wrapper for physical-design experiments.
// Software/test logic writes the 64 weights and eight activation lanes through
// indexed ports, then commits/launches them into the unchanged 8x8 core.
module systolic_array_pd_top (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        weight_we,
    input  logic [5:0]  weight_addr,
    input  logic [7:0]  weight_wdata,
    input  logic        weight_commit,

    input  logic        activation_we,
    input  logic [2:0]  activation_lane,
    input  logic [7:0]  activation_wdata,
    input  logic        activation_launch,

    input  logic [2:0]  result_col,
    output logic [31:0] result_rdata,
    output logic        result_valid
);

    localparam integer ROWS = 8;
    localparam integer COLS = 8;

    logic [ROWS*COLS*8-1:0] weights_q;
    logic [ROWS*8-1:0] activations_q;
    logic [COLS-1:0] array_output_valid;
    logic [COLS*32-1:0] array_results;
    logic [COLS-1:0] result_valid_q;
    logic [COLS*32-1:0] result_q;
    integer col;

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_W(8),
        .ACC_W(32)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .weight_load(weight_commit),
        .weights(weights_q),
        .input_valid(activation_launch),
        .activations(activations_q),
        .output_valid(array_output_valid),
        .results(array_results)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weights_q      <= '0;
            activations_q  <= '0;
            result_valid_q <= '0;
            result_q       <= '0;
        end else begin
            result_valid_q <= array_output_valid;
            if (weight_we)
                weights_q[(weight_addr*8) +: 8] <= weight_wdata;
            if (activation_we)
                activations_q[(activation_lane*8) +: 8] <= activation_wdata;
            for (col = 0; col < COLS; col = col + 1)
                if (array_output_valid[col])
                    result_q[(col*32) +: 32] <= array_results[(col*32) +: 32];
        end
    end

    always @* begin
        result_rdata = result_q[(result_col*32) +: 32];
        result_valid = result_valid_q[result_col];
    end

endmodule
