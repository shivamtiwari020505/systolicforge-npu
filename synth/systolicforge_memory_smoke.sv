`timescale 1ns/1ps

// Synthesis-only harness for the proposed default-depth storage organization.
// It proves that each logical memory can be expressed through the portable
// synchronous SDP primitive. This is not the redesigned NPU controller.
module systolicforge_memory_smoke (
    input  logic         clk,
    input  logic [1:0]   memory_select,
    input  logic         write_enable,
    input  logic [11:0]  write_address,
    input  logic [127:0] write_data,
    input  logic         read_enable,
    input  logic [11:0]  read_address,
    output logic [127:0] read_data
);

    logic [7:0]   a_read_data;
    logic [7:0]   b_read_data;
    logic [31:0]  c_read_data;
    logic [127:0] instruction_read_data;

    systolicforge_sdp_ram #(.DATA_W(8), .ADDR_W(12), .DEPTH(4096)) u_a (
        .clk(clk),
        .write_enable(write_enable && (memory_select == 2'd0)),
        .write_address(write_address),
        .write_data(write_data[7:0]),
        .read_enable(read_enable && (memory_select == 2'd0)),
        .read_address(read_address),
        .read_data(a_read_data)
    );

    systolicforge_sdp_ram #(.DATA_W(8), .ADDR_W(12), .DEPTH(4096)) u_b (
        .clk(clk),
        .write_enable(write_enable && (memory_select == 2'd1)),
        .write_address(write_address),
        .write_data(write_data[7:0]),
        .read_enable(read_enable && (memory_select == 2'd1)),
        .read_address(read_address),
        .read_data(b_read_data)
    );

    systolicforge_sdp_ram #(.DATA_W(32), .ADDR_W(12), .DEPTH(4096)) u_c (
        .clk(clk),
        .write_enable(write_enable && (memory_select == 2'd2)),
        .write_address(write_address),
        .write_data(write_data[31:0]),
        .read_enable(read_enable && (memory_select == 2'd2)),
        .read_address(read_address),
        .read_data(c_read_data)
    );

    // Only the low eight address bits are meaningful for the 256-word IMEM.
    systolicforge_sdp_ram #(.DATA_W(128), .ADDR_W(8), .DEPTH(256)) u_imem (
        .clk(clk),
        .write_enable(write_enable && (memory_select == 2'd3)),
        .write_address(write_address[7:0]),
        .write_data(write_data),
        .read_enable(read_enable && (memory_select == 2'd3)),
        .read_address(read_address[7:0]),
        .read_data(instruction_read_data)
    );

    always_comb begin
        read_data = '0;
        case (memory_select)
            2'd0: read_data[7:0] = a_read_data;
            2'd1: read_data[7:0] = b_read_data;
            2'd2: read_data[31:0] = c_read_data;
            2'd3: read_data = instruction_read_data;
            default: read_data = '0;
        endcase
    end

endmodule
