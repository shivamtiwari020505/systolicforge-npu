`timescale 1ns/1ps

module tb_systolic_array;

`ifdef GATE_SIM
    localparam integer ROWS   = 8;
    localparam integer COLS   = 8;
`else
    localparam integer ROWS   = 4;
    localparam integer COLS   = 4;
`endif
    localparam integer DATA_W = 8;
    localparam integer ACC_W  = 32;
    localparam integer M      = 6;

    logic clk;
    logic rst_n;
    logic weight_load;
    logic [ROWS*COLS*DATA_W-1:0] weights;
    logic input_valid;
    logic [ROWS*DATA_W-1:0] activations;
    logic [COLS-1:0] output_valid;
    logic [COLS*ACC_W-1:0] results;

    integer signed a [0:M-1][0:ROWS-1];
    integer signed b [0:ROWS-1][0:COLS-1];
    integer signed expected [0:M-1][0:COLS-1];
    integer received [0:COLS-1];
    integer errors;
    integer i;
    integer j;
    integer k;
    integer signed actual;

`ifdef GATE_SIM
    systolic_array dut (
`else
    systolic_array #(
        .ROWS(ROWS),
        .COLS(COLS),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
`endif
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
            for (j = 0; j < COLS; j = j + 1) begin
                if (output_valid[j]) begin
                    actual = $signed(results[(j*ACC_W) +: ACC_W]);
                    if (received[j] >= M) begin
                        $display("ERROR: unexpected extra result on column %0d: %0d", j, actual);
                        errors = errors + 1;
                    end else if (actual !== expected[received[j]][j]) begin
                        $display(
                            "ERROR: C[%0d][%0d] expected %0d, got %0d",
                            received[j], j, expected[received[j]][j], actual
                        );
                        errors = errors + 1;
                    end
                    received[j] = received[j] + 1;
                end
            end
        end
    end

    task automatic drive_row(input integer row);
        integer lane;
        begin
            @(negedge clk);
            input_valid = 1'b1;
            for (lane = 0; lane < ROWS; lane = lane + 1)
                activations[(lane*DATA_W) +: DATA_W] = a[row][lane][DATA_W-1:0];
        end
    endtask

    task automatic drive_idle;
        begin
            @(negedge clk);
            input_valid = 1'b0;
            activations = '0;
        end
    endtask

    initial begin
        clk          = 1'b0;
        rst_n        = 1'b0;
        weight_load  = 1'b0;
        input_valid  = 1'b0;
        weights      = '0;
        activations  = '0;
        errors       = 0;

        for (j = 0; j < COLS; j = j + 1)
            received[j] = 0;

        // Deliberately asymmetric signed matrices catch lane-order and sign bugs.
        for (i = 0; i < M; i = i + 1) begin
            for (k = 0; k < ROWS; k = k + 1)
                a[i][k] = ((i * 7 + k * 3) % 17) - 8;
        end
        for (k = 0; k < ROWS; k = k + 1) begin
            for (j = 0; j < COLS; j = j + 1)
                b[k][j] = ((k * 5 + j * 11) % 19) - 9;
        end
        for (i = 0; i < M; i = i + 1) begin
            for (j = 0; j < COLS; j = j + 1) begin
                expected[i][j] = 0;
                for (k = 0; k < ROWS; k = k + 1)
                    expected[i][j] = expected[i][j] + a[i][k] * b[k][j];
            end
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (k = 0; k < ROWS; k = k + 1)
            for (j = 0; j < COLS; j = j + 1)
                weights[((k*COLS+j)*DATA_W) +: DATA_W] = b[k][j][DATA_W-1:0];

        @(negedge clk);
        weight_load = 1'b1;
        @(negedge clk);
        weight_load = 1'b0;

        // A bubble proves that valid state travels with the systolic wavefront.
        drive_row(0);
        drive_row(1);
        drive_idle();
        drive_row(2);
        drive_row(3);
        drive_row(4);
        drive_row(5);
        drive_idle();

        repeat (ROWS + COLS + M + 5) @(negedge clk);

        for (j = 0; j < COLS; j = j + 1) begin
            if (received[j] != M) begin
                $display("ERROR: column %0d produced %0d/%0d results", j, received[j], M);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: systolic array produced all %0d signed matrix results", M*COLS);
        else
            $display("FAIL: %0d error(s)", errors);

        $finish(errors != 0);
    end

endmodule
