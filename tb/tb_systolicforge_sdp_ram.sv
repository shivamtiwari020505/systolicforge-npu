`timescale 1ns/1ps

module tb_systolicforge_sdp_ram;

    localparam integer DATA_W = 32;
    localparam integer ADDR_W = 12;
    localparam integer DEPTH  = (1 << ADDR_W);

    logic clk;
    logic write_enable;
    logic [ADDR_W-1:0] write_address;
    logic [DATA_W-1:0] write_data;
    logic read_enable;
    logic [ADDR_W-1:0] read_address;
    logic [DATA_W-1:0] read_data;

    integer errors;

    systolicforge_sdp_ram #(
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .write_enable(write_enable),
        .write_address(write_address),
        .write_data(write_data),
        .read_enable(read_enable),
        .read_address(read_address),
        .read_data(read_data)
    );

    always #5 clk = ~clk;

    task automatic write_word(
        input logic [ADDR_W-1:0] address,
        input logic [DATA_W-1:0] data
    );
        begin
            @(negedge clk);
            write_enable  = 1'b1;
            write_address = address;
            write_data    = data;
            @(negedge clk);
            write_enable = 1'b0;
        end
    endtask

    task automatic read_and_expect(
        input logic [ADDR_W-1:0] address,
        input logic [DATA_W-1:0] expected
    );
        begin
            @(negedge clk);
            read_enable  = 1'b1;
            read_address = address;
            @(posedge clk);
            #1;
            if (read_data !== expected) begin
                $display("ERROR: address %0d expected 0x%08h, got 0x%08h",
                         address, expected, read_data);
                errors = errors + 1;
            end
            @(negedge clk);
            read_enable = 1'b0;
        end
    endtask

    initial begin
        clk           = 1'b0;
        write_enable  = 1'b0;
        write_address = '0;
        write_data    = '0;
        read_enable   = 1'b0;
        read_address  = '0;
        errors        = 0;

        // The first and last words exercise the complete default-depth address
        // range without depending on uninitialized memory contents.
        write_word(12'd0,    32'h0123_4567);
        write_word(12'd37,   32'h89ab_cdef);
        write_word(12'd4095, 32'h8000_0001);

        read_and_expect(12'd0,    32'h0123_4567);
        read_and_expect(12'd37,   32'h89ab_cdef);
        read_and_expect(12'd4095, 32'h8000_0001);

        // Disabled reads must retain the registered output.
        @(negedge clk);
        read_enable  = 1'b0;
        read_address = 12'd0;
        @(posedge clk);
        #1;
        if (read_data !== 32'h8000_0001) begin
            $display("ERROR: disabled read did not hold the previous output");
            errors = errors + 1;
        end

        // The portable contract is read-first for a same-address collision.
        @(negedge clk);
        write_enable  = 1'b1;
        write_address = 12'd37;
        write_data    = 32'hfeed_face;
        read_enable   = 1'b1;
        read_address  = 12'd37;
        @(posedge clk);
        #1;
        if (read_data !== 32'h89ab_cdef) begin
            $display("ERROR: collision was not read-first; got 0x%08h", read_data);
            errors = errors + 1;
        end

        @(negedge clk);
        write_enable = 1'b0;
        read_enable  = 1'b0;
        read_and_expect(12'd37, 32'hfeed_face);

        if (errors == 0)
            $display("PASS: full-depth synchronous SDP RAM contract");
        else
            $fatal(1, "FAIL: %0d synchronous SDP RAM error(s)", errors);

        $finish;
    end

endmodule
