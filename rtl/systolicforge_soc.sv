`timescale 1ns/1ps

module systolicforge_soc #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 8,
    parameter integer ADDR_W     = 12,
    parameter integer IMEM_DEPTH = 256,
    parameter integer EXT_ADDR_W = 32
) (
    input  logic                           clk,
    input  logic                           rst_n,

    input  logic                           program_we,
    input  logic [$clog2(IMEM_DEPTH)-1:0]  program_addr,
    input  logic [127:0]                   program_wdata,

    input  logic                           start,
    output logic                           busy,
    output logic                           done,
    output logic                           fault,
    output logic [3:0]                     fault_code,

    input  logic                           dma_cmd_valid,
    output logic                           dma_cmd_ready,
    input  logic                           dma_cmd_to_local,
    input  logic [1:0]                     dma_cmd_mem,
    input  logic [ADDR_W-1:0]              dma_cmd_local_addr,
    input  logic [EXT_ADDR_W-1:0]          dma_cmd_ext_addr,
    input  logic [15:0]                    dma_cmd_length,
    output logic                           dma_busy,
    output logic                           dma_done,

    output logic                           ext_req_valid,
    input  logic                           ext_req_ready,
    output logic                           ext_req_write,
    output logic [EXT_ADDR_W-1:0]          ext_req_addr,
    output logic [31:0]                    ext_req_wdata,
    input  logic                           ext_rsp_valid,
    input  logic [31:0]                    ext_rsp_rdata
);

    logic local_valid;
    logic local_ready;
    logic local_write;
    logic [1:0] local_mem;
    logic [ADDR_W-1:0] local_addr;
    logic [31:0] local_wdata;
    logic [31:0] local_rdata;
    logic [$clog2(IMEM_DEPTH)-1:0] unused_pc;
    logic npu_fault;
    logic [3:0] npu_fault_code;
    logic dma_fault;
    logic [3:0] dma_fault_code;

    assign fault = npu_fault || dma_fault;
    assign fault_code = npu_fault ? npu_fault_code : dma_fault_code;

    scratchpad_dma #(
        .LOCAL_ADDR_W(ADDR_W),
        .EXT_ADDR_W  (EXT_ADDR_W),
        .DATA_W      (32)
    ) u_dma (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(dma_cmd_valid),
        .cmd_ready(dma_cmd_ready),
        .cmd_to_local(dma_cmd_to_local),
        .cmd_mem(dma_cmd_mem),
        .cmd_local_addr(dma_cmd_local_addr),
        .cmd_ext_addr(dma_cmd_ext_addr),
        .cmd_length(dma_cmd_length),
        .busy(dma_busy),
        .done(dma_done),
        .fault(dma_fault),
        .fault_code(dma_fault_code),
        .local_valid(local_valid),
        .local_ready(local_ready),
        .local_write(local_write),
        .local_mem(local_mem),
        .local_addr(local_addr),
        .local_wdata(local_wdata),
        .local_rdata(local_rdata),
        .ext_req_valid(ext_req_valid),
        .ext_req_ready(ext_req_ready),
        .ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),
        .ext_req_wdata(ext_req_wdata),
        .ext_rsp_valid(ext_rsp_valid),
        .ext_rsp_rdata(ext_rsp_rdata)
    );

    systolicforge_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH)
    ) u_npu (
        .clk(clk),
        .rst_n(rst_n),
        .program_we(program_we),
        .program_addr(program_addr),
        .program_wdata(program_wdata),
        .dma_valid(local_valid),
        .dma_ready(local_ready),
        .dma_write(local_write),
        .dma_mem(local_mem),
        .dma_addr(local_addr),
        .dma_wdata(local_wdata),
        .dma_rdata(local_rdata),
        .start(start && !dma_busy && !(dma_cmd_valid && dma_cmd_ready)),
        .busy(busy),
        .done(done),
        .fault(npu_fault),
        .fault_code(npu_fault_code),
        .pc_debug(unused_pc)
    );

endmodule
