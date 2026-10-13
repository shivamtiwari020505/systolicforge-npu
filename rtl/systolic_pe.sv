`timescale 1ns/1ps

module systolic_pe #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32,
    parameter bit     TOP_ROW = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         weight_load,
    input  logic signed [DATA_W-1:0]     weight_in,
    input  logic signed [DATA_W-1:0]     activation_in,
    input  logic                         activation_valid_in,
    input  logic signed [ACC_W-1:0]      psum_in,
    input  logic                         psum_valid_in,
    output logic signed [DATA_W-1:0]     activation_out,
    output logic                         activation_valid_out,
    output logic signed [ACC_W-1:0]      psum_out,
    output logic                         psum_valid_out
);

    logic signed [DATA_W-1:0] weight_q;
    // An 8x8 array uses 64 multipliers, which fits the Basys3's 90 DSP48E1
    // blocks. Prefer DSP mapping to reduce LUT congestion and routing delay.
    (* use_dsp = "yes" *)
    wire signed [(2*DATA_W)-1:0] product = activation_in * weight_q;
    wire signed [ACC_W-1:0] product_ext =
        {{(ACC_W-(2*DATA_W)){product[2*DATA_W-1]}}, product};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_q            <= '0;
            activation_out      <= '0;
            activation_valid_out <= 1'b0;
            psum_out            <= '0;
            psum_valid_out      <= 1'b0;
        end else begin
            if (weight_load)
                weight_q <= weight_in;

            activation_out       <= activation_in;
            activation_valid_out <= activation_valid_in;

            if (TOP_ROW) begin
                psum_valid_out <= activation_valid_in;
                if (activation_valid_in)
                    psum_out <= product_ext;
            end else begin
                psum_valid_out <= activation_valid_in && psum_valid_in;
                if (activation_valid_in && psum_valid_in)
                    psum_out <= psum_in + product_ext;
            end
        end
    end

endmodule
