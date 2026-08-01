`timescale 1ns/1ps

module tb_fpga_demo;
    logic clk;
    logic reset_button;
    logic start_button;
    logic [15:0] leds;
    integer cycles;
    integer errors;

    systolicforge_fpga_demo dut (
        .clk(clk),
        .reset_button(reset_button),
        .start_button(start_button),
        .leds(leds)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        reset_button = 1'b1;
        start_button = 1'b0;
        errors = 0;

        repeat (3) @(negedge clk);
        reset_button = 1'b0;
        repeat (2) @(negedge clk);
        start_button = 1'b1;
        repeat (3) @(negedge clk);
        start_button = 1'b0;

        cycles = 0;
        while (!leds[0] && !leds[1] && cycles < 100) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        if (!leds[0]) begin
            $display("ERROR: FPGA self-test did not assert PASS, leds=%h", leds);
            errors = errors + 1;
        end
        if (leds[1]) begin
            $display("ERROR: FPGA self-test asserted FAIL");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: FPGA demo completed its hardware self-test in %0d cycles", cycles);
        else
            $display("FAIL: %0d error(s)", errors);
        $finish(errors != 0);
    end
endmodule
