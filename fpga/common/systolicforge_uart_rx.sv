`timescale 1ns/1ps

module systolicforge_uart_rx #(
    parameter integer CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       data_valid,
    output logic       framing_error
);

    localparam integer COUNT_W = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT);
    localparam integer HALF_BIT = (CLKS_PER_BIT - 1) / 2;

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t state_q;
    (* ASYNC_REG = "TRUE" *) logic rx_meta_q;
    (* ASYNC_REG = "TRUE" *) logic rx_sync_q;
    logic [COUNT_W-1:0] count_q;
    logic [2:0] bit_q;
    logic [7:0] data_q;

    assign data = data_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
        end else begin
            rx_meta_q <= rx;
            rx_sync_q <= rx_meta_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q       <= RX_IDLE;
            count_q       <= '0;
            bit_q         <= '0;
            data_q        <= '0;
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            data_valid    <= 1'b0;
            framing_error <= 1'b0;

            case (state_q)
                RX_IDLE: begin
                    count_q <= '0;
                    if (!rx_sync_q)
                        state_q <= RX_START;
                end

                RX_START: begin
                    if (count_q == HALF_BIT) begin
                        count_q <= '0;
                        if (!rx_sync_q) begin
                            bit_q   <= '0;
                            state_q <= RX_DATA;
                        end else begin
                            state_q <= RX_IDLE;
                        end
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (count_q == CLKS_PER_BIT - 1) begin
                        count_q       <= '0;
                        data_q[bit_q] <= rx_sync_q;
                        if (bit_q == 3'd7)
                            state_q <= RX_STOP;
                        else
                            bit_q <= bit_q + 1'b1;
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (count_q == CLKS_PER_BIT - 1) begin
                        count_q       <= '0;
                        data_valid    <= 1'b1;
                        framing_error <= !rx_sync_q;
                        state_q       <= RX_IDLE;
                    end else begin
                        count_q <= count_q + 1'b1;
                    end
                end

                default: state_q <= RX_IDLE;
            endcase
        end
    end

endmodule
