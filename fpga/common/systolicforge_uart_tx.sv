`timescale 1ns/1ps

module systolicforge_uart_tx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data,
    input  logic       data_valid,
    output logic       data_ready,
    output logic       tx
);

    localparam integer COUNT_W = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t state_q;
    logic [COUNT_W-1:0] count_q;
    logic [2:0] bit_q;
    logic [7:0] data_q;

    assign data_ready = (state_q == TX_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= TX_IDLE;
            count_q <= '0;
            bit_q   <= '0;
            data_q  <= '0;
            tx      <= 1'b1;
        end else begin
            case (state_q)
                TX_IDLE: begin
                    tx      <= 1'b1;
                    count_q <= '0;
                    if (data_valid) begin
                        data_q  <= data;
                        bit_q   <= '0;
                        tx      <= 1'b0;
                        state_q <= TX_START;
                    end
                end

                TX_START: begin
                    if (count_q == CLKS_PER_BIT - 1) begin
                        count_q <= '0;
                        tx      <= data_q[0];
                        state_q <= TX_DATA;
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                TX_DATA: begin
                    if (count_q == CLKS_PER_BIT - 1) begin
                        count_q <= '0;
                        if (bit_q == 3'd7) begin
                            tx      <= 1'b1;
                            state_q <= TX_STOP;
                        end else begin
                            bit_q <= bit_q + 1'b1;
                            tx    <= data_q[bit_q + 1'b1];
                        end
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                TX_STOP: begin
                    if (count_q == CLKS_PER_BIT - 1) begin
                        count_q <= '0;
                        state_q <= TX_IDLE;
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                default: state_q <= TX_IDLE;
            endcase
        end
    end

endmodule
