`timescale 1ns/1ps

module tb_systolic_array_arithmetic_edges;

    localparam integer ROWS = 4;
    localparam integer COLS = 4;
    localparam integer DATA_W = 8;
    // A narrow verification-only accumulator makes signed wrap reachable with
    // a small physical array. Production/default configurations remain 32-bit.
    localparam integer ACC_W = 16;
    localparam integer ZERO_ROWS = 3;
    localparam integer OVERFLOW_ROWS = 2;
    // Four products of 127*127 total 64516 = 16'hfc04 = -1020 signed.
    localparam integer signed OVERFLOW_EXPECTED = -1020;

    localparam integer PHASE_ZERO = 0;
    localparam integer PHASE_OVERFLOW = 1;

    logic clk;
    logic rst_n;
    logic weight_load;
    logic [ROWS*COLS*DATA_W-1:0] weights;
    logic input_valid;
    logic [ROWS*DATA_W-1:0] activations;
    logic [COLS-1:0] output_valid;
    logic [COLS*ACC_W-1:0] results;

    integer received [0:COLS-1];
    integer current_phase;
    integer expected_rows;
    integer signed expected_value;
    integer signed actual;
    integer errors;
    integer column;

    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .weight_load(weight_load),
        .weights(weights),
        .input_valid(input_valid),
        .activations(activations),
        .output_valid(output_valid),
        .results(results)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (rst_n) begin
            for (column = 0; column < COLS; column = column + 1) begin
                if (output_valid[column]) begin
                    actual = $signed(results[(column*ACC_W) +: ACC_W]);
                    if (received[column] >= expected_rows) begin
                        $display(
                            "ERROR: phase %0d column %0d produced an extra result %0d",
                            current_phase, column, actual
                        );
                        errors = errors + 1;
                    end else if (actual !== expected_value) begin
                        $display(
                            "ERROR: phase %0d result[%0d][%0d] expected %0d, got %0d",
                            current_phase, received[column], column,
                            expected_value, actual
                        );
                        errors = errors + 1;
                    end
                    received[column] = received[column] + 1;
                end
            end
        end
    end

    task automatic reset_phase(
        input integer phase,
        input integer row_count,
        input integer signed result_value
    );
        integer index;
        begin
            rst_n = 1'b0;
            weight_load = 1'b0;
            input_valid = 1'b0;
            weights = '0;
            activations = '0;
            current_phase = phase;
            expected_rows = row_count;
            expected_value = result_value;
            for (index = 0; index < COLS; index = index + 1)
                received[index] = 0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic load_uniform_weights(input integer signed value);
        integer row;
        integer col;
        begin
            for (row = 0; row < ROWS; row = row + 1)
                for (col = 0; col < COLS; col = col + 1)
                    weights[((row*COLS+col)*DATA_W) +: DATA_W] =
                        value[DATA_W-1:0];
            @(negedge clk);
            weight_load = 1'b1;
            @(negedge clk);
            weight_load = 1'b0;
        end
    endtask

    task automatic drive_uniform_row(input integer signed value);
        integer lane;
        begin
            @(negedge clk);
            input_valid = 1'b1;
            for (lane = 0; lane < ROWS; lane = lane + 1)
                activations[(lane*DATA_W) +: DATA_W] = value[DATA_W-1:0];
        end
    endtask

    task automatic drive_idle;
        begin
            @(negedge clk);
            input_valid = 1'b0;
            activations = '0;
        end
    endtask

    task automatic finish_phase;
        integer index;
        begin
            drive_idle();
            repeat (ROWS + COLS + expected_rows + 3) @(negedge clk);
            #1;
            for (index = 0; index < COLS; index = index + 1) begin
                if (received[index] != expected_rows) begin
                    $display(
                        "ERROR: phase %0d column %0d produced %0d/%0d results",
                        current_phase, index, received[index], expected_rows
                    );
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        weight_load = 1'b0;
        input_valid = 1'b0;
        weights = '0;
        activations = '0;
        errors = 0;

        // Nonzero weights make this a meaningful zero-activation test rather
        // than allowing a broken weight path to produce the expected zero.
        reset_phase(PHASE_ZERO, ZERO_ROWS, 0);
        load_uniform_weights(127);
        repeat (ZERO_ROWS)
            drive_uniform_row(0);
        finish_phase();

        // Reset isolates the phases. This reduction intentionally exceeds the
        // signed 16-bit range and must retain the low two's-complement bits.
        reset_phase(PHASE_OVERFLOW, OVERFLOW_ROWS, OVERFLOW_EXPECTED);
        load_uniform_weights(127);
        repeat (OVERFLOW_ROWS)
            drive_uniform_row(127);
        finish_phase();

        if (errors == 0) begin
            $display(
                "PASS: array zero-input and signed accumulator-wrap edge cases"
            );
        end else begin
            $display("FAIL: %0d array arithmetic edge-case error(s)", errors);
        end
        $finish(errors != 0);
    end

endmodule
