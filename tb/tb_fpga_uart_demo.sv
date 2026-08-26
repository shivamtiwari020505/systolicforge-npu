`timescale 1ns/1ps

module tb_fpga_uart_demo;
    localparam integer CLKS_PER_BIT = 8;

    localparam logic [7:0] CMD_PING          = 8'h00;
    localparam logic [7:0] CMD_STATUS        = 8'h01;
    localparam logic [7:0] CMD_WRITE_PROGRAM = 8'h10;
    localparam logic [7:0] CMD_WRITE_MEMORY  = 8'h11;
    localparam logic [7:0] CMD_READ_MEMORY   = 8'h12;
    localparam logic [7:0] CMD_START         = 8'h20;

    localparam logic [7:0] RESPONSE_OK           = 8'h00;
    localparam logic [7:0] RESPONSE_BUSY         = 8'h01;
    localparam logic [7:0] RESPONSE_BAD_ARGUMENT = 8'h03;

    logic clk;
    logic reset_button;
    logic start_button;
    logic uart_rx;
    logic uart_tx;
    logic [15:0] leds;

    logic [7:0] monitor_data;
    logic monitor_valid;
    logic monitor_framing_error;

    logic [7:0] received_command;
    logic [7:0] received_status;
    logic [31:0] received_data;
    logic [127:0] instruction;
    integer errors;
    integer cycles;

    systolicforge_fpga_uart_demo #(
        .UART_CLKS_PER_BIT(CLKS_PER_BIT),
        .ADDR_W(7),
        .IMEM_DEPTH(16)
    ) dut (
        .clk(clk),
        .reset_button(reset_button),
        .start_button(start_button),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .leds(leds)
    );

    systolicforge_uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_tx_monitor (
        .clk(clk),
        .rst_n(!reset_button),
        .rx(uart_tx),
        .data(monitor_data),
        .data_valid(monitor_valid),
        .framing_error(monitor_framing_error)
    );

    always #5 clk = ~clk;

    task automatic send_uart_byte(input logic [7:0] value);
        integer bit_index;
        begin
            uart_rx = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic receive_uart_byte(output logic [7:0] value);
        integer timeout;
        begin
            timeout = 0;
            while (!monitor_valid && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!monitor_valid) begin
                $display("ERROR: timed out waiting for UART response byte");
                errors = errors + 1;
                value = 8'hxx;
            end else begin
                value = monitor_data;
                if (monitor_framing_error) begin
                    $display("ERROR: UART response had a framing error");
                    errors = errors + 1;
                end
                @(posedge clk);
            end
        end
    endtask

    task automatic receive_response;
        logic [7:0] byte_value;
        logic [7:0] bytes [0:5];
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 6; byte_index = byte_index + 1) begin
                receive_uart_byte(byte_value);
                bytes[byte_index] = byte_value;
            end
            received_command = bytes[0];
            received_status = bytes[1];
            received_data = {bytes[5], bytes[4], bytes[3], bytes[2]};
        end
    endtask

    task automatic expect_response(
        input logic [7:0] expected_command,
        input logic [7:0] expected_status,
        input logic [31:0] expected_data,
        input logic check_data
    );
        begin
            receive_response();
            if (received_command !== expected_command) begin
                $display("ERROR: response command got %02x expected %02x",
                         received_command, expected_command);
                errors = errors + 1;
            end
            if (received_status !== expected_status) begin
                $display("ERROR: response status got %02x expected %02x",
                         received_status, expected_status);
                errors = errors + 1;
            end
            if (check_data && (received_data !== expected_data)) begin
                $display("ERROR: response data got %08x expected %08x",
                         received_data, expected_data);
                errors = errors + 1;
            end
        end
    endtask

    task automatic write_program(
        input logic [7:0] address,
        input logic [127:0] word
    );
        integer byte_index;
        begin
            send_uart_byte(CMD_WRITE_PROGRAM);
            send_uart_byte(address);
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                send_uart_byte(word[(byte_index*8) +: 8]);
            expect_response(8'h90, RESPONSE_OK, 32'd0, 1'b1);
        end
    endtask

    task automatic write_memory(
        input logic [7:0] memory,
        input logic [7:0] address,
        input logic [31:0] value
    );
        integer byte_index;
        begin
            send_uart_byte(CMD_WRITE_MEMORY);
            send_uart_byte(memory);
            send_uart_byte(address);
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                send_uart_byte(value[(byte_index*8) +: 8]);
            expect_response(8'h91, RESPONSE_OK, 32'd0, 1'b1);
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_button = 1'b1;
        start_button = 1'b0;
        uart_rx = 1'b1;
        errors = 0;

        repeat (5) @(posedge clk);
        reset_button = 1'b0;
        repeat (5) @(posedge clk);

        send_uart_byte(CMD_PING);
        expect_response(8'h80, RESPONSE_OK, 32'h53464e50, 1'b1);

        // Start the retained button-driven self-test, then prove that the UART
        // cannot take ownership of the NPU while the test is loading data.
        start_button = 1'b1;
        repeat (3) @(posedge clk);
        start_button = 1'b0;
        cycles = 0;
        while (!leds[2] && cycles < 50) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!leds[2]) begin
            $display("ERROR: button self-test did not become active");
            errors = errors + 1;
        end

        send_uart_byte(CMD_START);
        expect_response(8'ha0, RESPONSE_BUSY, 32'd0, 1'b1);

        cycles = 0;
        while (!leds[0] && !leds[1] && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!leds[0] || leds[1]) begin
            $display("ERROR: shared-NPU button self-test failed, leds=%h", leds);
            errors = errors + 1;
        end

        // Program a 1x1 signed MatMul, write A/B, execute it, and read C back
        // entirely through the physical UART byte stream.
        instruction = {
            16'd1, 16'd1, 16'd1,
            16'd0, 16'd0, 16'd0,
            8'd1, 8'd1, 8'd1, 4'd0, 4'h1
        };
        write_program(8'd0, instruction);
        write_program(8'd1, 128'hf);
        write_memory(8'd0, 8'd0, -32'sd3);
        write_memory(8'd1, 8'd0, 32'sd7);

        send_uart_byte(CMD_START);
        expect_response(8'ha0, RESPONSE_OK, 32'd0, 1'b1);

        send_uart_byte(CMD_STATUS);
        receive_response();
        if (received_command !== 8'h81 || received_status !== RESPONSE_OK) begin
            $display("ERROR: malformed STATUS response command=%02x status=%02x",
                     received_command, received_status);
            errors = errors + 1;
        end
        if (!received_data[1] || received_data[2] || (received_data[31:16] != 16'h0001)) begin
            $display("ERROR: unexpected completed STATUS word %08x", received_data);
            errors = errors + 1;
        end

        send_uart_byte(CMD_READ_MEMORY);
        send_uart_byte(8'd2);
        send_uart_byte(8'd0);
        expect_response(8'h92, RESPONSE_OK, -32'sd21, 1'b1);

        // Invalid memory selectors are rejected and never reach the NPU.
        send_uart_byte(CMD_READ_MEMORY);
        send_uart_byte(8'd3);
        send_uart_byte(8'd0);
        expect_response(8'h92, RESPONSE_BAD_ARGUMENT, 32'd0, 1'b1);

        if (errors == 0)
            $display("PASS: UART loaded/executed/read a signed MatMul and retained the button self-test");
        else
            $display("FAIL: %0d UART FPGA demo error(s)", errors);
        $finish(errors != 0);
    end

endmodule
