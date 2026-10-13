`timescale 1ns/1ps

// Portable one-clock simple-dual-port RAM building block.
//
// A read request presented before a rising edge updates read_data immediately
// after that edge. When read_enable is low, read_data holds its previous value.
// A same-address read/write collision returns the old word (read-first mode).
//
// The storage array and output intentionally have no reset. Controllers must
// track validity and must initialize every location before consuming it. This
// coding style matches FPGA block-RAM inference templates and also maps cleanly
// to a synchronous SRAM wrapper in a future ASIC flow.
module systolicforge_sdp_ram #(
    parameter integer DATA_W = 32,
    parameter integer ADDR_W = 12,
    parameter integer DEPTH  = (1 << ADDR_W)
) (
    input  logic                  clk,

    input  logic                  write_enable,
    input  logic [ADDR_W-1:0]     write_address,
    input  logic [DATA_W-1:0]     write_data,

    input  logic                  read_enable,
    input  logic [ADDR_W-1:0]     read_address,
    output logic [DATA_W-1:0]     read_data
);

    (* ram_style = "block" *) logic [DATA_W-1:0] memory [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;

        if (read_enable)
            read_data <= memory[read_address];
    end

endmodule
