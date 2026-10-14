`timescale 1ns/1ps

// Fixed-latency MATMUL validation shared by the general and compact engines.
// Split subtract/operand capture, 8x16 multiply, 25-bit add, and comparison.
// Do not truncate bases/strides to ADDR_W before checking their full ISA range.
// Reset is synchronous; the data pipeline needs no reset because valid gates it.
module systolicforge_matmul_validator #(
    parameter integer ARRAY_ROWS = 8, ARRAY_COLS = 8, ADDR_W = 12
) (
    input logic clk, rst_n, request,
    input logic [127:0] instruction,
    input logic pc_at_last,
    output logic valid,
    output logic [3:0] fault_code
);
    logic [2:0] valid_q;
    logic [7:0] m_minus_q, k_minus_q;
    logic [15:0] lda_q, ldb_q, ldc_q;
    logic [24:0] a_tail_q, b_tail_q, c_tail_q;
    (* use_dsp = "yes" *) logic [23:0] a_product_q, b_product_q, c_product_q;
    logic [24:0] a_tail_pipe_q, b_tail_pipe_q, c_tail_pipe_q;
    logic [24:0] a_end_q, b_end_q, c_end_q;
    logic [3:0] early_fault_q [0:2];

    // Largest legal ISA address is less than 2^25 (8-bit size, 16-bit stride).
    localparam logic [24:0] DEPTH = 25'd1 << ADDR_W;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_q <= '0;
            valid <= 1'b0;
            fault_code <= '0;
        end else begin
            valid_q <= {valid_q[1:0], request};
            valid <= valid_q[2];
            if (valid_q[2]) begin
                if (early_fault_q[2] != 0)
                    fault_code <= early_fault_q[2];
                else if ((a_end_q >= DEPTH) || (b_end_q >= DEPTH) ||
                         (c_end_q >= DEPTH))
                    fault_code <= 4'h3;
                else
                    fault_code <= '0;
            end
        end

        if (rst_n && request) begin
            m_minus_q <= instruction[15:8] - 8'd1;
            k_minus_q <= instruction[23:16] - 8'd1;
            lda_q <= instruction[95:80];
            ldb_q <= instruction[111:96];
            ldc_q <= instruction[127:112];
            a_tail_q <= 25'(instruction[47:32]) +
                        25'(instruction[23:16]) - 25'd1;
            b_tail_q <= 25'(instruction[63:48]) +
                        25'(instruction[31:24]) - 25'd1;
            c_tail_q <= 25'(instruction[79:64]) +
                        25'(instruction[31:24]) - 25'd1;
            if ((instruction[15:8] == 0) || (instruction[23:16] == 0) ||
                (instruction[31:24] == 0) ||
                (instruction[23:16] > ARRAY_ROWS) ||
                (instruction[31:24] > ARRAY_COLS))
                early_fault_q[0] <= 4'h2;
            else if (pc_at_last)
                early_fault_q[0] <= 4'h4;
            else
                early_fault_q[0] <= '0;
        end
        if (rst_n && valid_q[0]) begin
            a_product_q <= m_minus_q * lda_q;
            b_product_q <= k_minus_q * ldb_q;
            c_product_q <= m_minus_q * ldc_q;
            a_tail_pipe_q <= a_tail_q;
            b_tail_pipe_q <= b_tail_q;
            c_tail_pipe_q <= c_tail_q;
            early_fault_q[1] <= early_fault_q[0];
        end
        if (rst_n && valid_q[1]) begin
            a_end_q <= {1'b0, a_product_q} + a_tail_pipe_q;
            b_end_q <= {1'b0, b_product_q} + b_tail_pipe_q;
            c_end_q <= {1'b0, c_product_q} + c_tail_pipe_q;
            early_fault_q[2] <= early_fault_q[1];
        end
    end
endmodule
