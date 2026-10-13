`timescale 1ns/1ps

// Full-depth numerical comparison with the pre-redesign engine. No reads of
// internal memories: both engines are initialized/checked through their ports.
module tb_npu_memory_redesign;
    logic clk = 0;
    logic rst_n = 0;
    logic program_we = 0;
    logic [7:0] program_addr = 0;
    logic [127:0] program_wdata = 0;
    logic dma_valid = 0, dma_write = 0, dma_ready, legacy_ready;
    logic [1:0] dma_mem = 0;
    logic [11:0] dma_addr = 0;
    logic [31:0] dma_wdata = 0, dma_rdata, legacy_data;
    logic start = 0, busy, done, fault, legacy_busy, legacy_done, legacy_fault;
    logic [3:0] fault_code, legacy_code;
    logic [7:0] pc, legacy_pc;
    integer test_case, row, col, k, m, ks, ns, lda, ldb, ldc;
    integer abase, bbase, cbase, span, addr, cycles, seed = 32'h52a671d;
    integer random_word, dot, value, initial_value;
    logic [31:0] golden [0:4095];
    logic [31:0] held_data;
    logic new_finished, old_finished;

    always #5 clk = ~clk;
    systolicforge_npu dut (
        .clk(clk), .rst_n(rst_n), .program_we(program_we),
        .program_addr(program_addr), .program_wdata(program_wdata),
        .dma_valid(dma_valid), .dma_ready(dma_ready), .dma_write(dma_write),
        .dma_mem(dma_mem), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_rdata(dma_rdata), .start(start), .busy(busy), .done(done),
        .fault(fault), .fault_code(fault_code), .pc_debug(pc)
    );
    systolicforge_npu_legacy legacy (
        .clk(clk), .rst_n(rst_n), .program_we(program_we),
        .program_addr(program_addr), .program_wdata(program_wdata),
        .dma_valid(dma_valid), .dma_ready(legacy_ready), .dma_write(dma_write),
        .dma_mem(dma_mem), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_rdata(legacy_data), .start(start), .busy(legacy_busy),
        .done(legacy_done), .fault(legacy_fault), .fault_code(legacy_code),
        .pc_debug(legacy_pc)
    );

    function automatic integer operand(input integer address, input integer salt);
        operand = (test_case == 2) ? 0 : ((address * 73 + salt) & 255) - 128;
    endfunction
    function automatic [127:0] inst(input integer accum);
        reg [127:0] word_value;
        begin
            word_value = '0;
            word_value[3:0] = 1;
            word_value[4] = (accum != 0);
            word_value[15:8] = 8'(m);
            word_value[23:16] = 8'(ks);
            word_value[31:24] = 8'(ns);
            word_value[47:32] = 16'(abase);
            word_value[63:48] = 16'(bbase);
            word_value[79:64] = 16'(cbase);
            word_value[95:80] = 16'(lda);
            word_value[111:96] = 16'(ldb);
            word_value[127:112] = 16'(ldc);
            inst = word_value;
        end
    endfunction
    task automatic program_word(input integer address, input [127:0] word_value);
        @(negedge clk);
        program_we = 1;
        program_addr = 8'(address);
        program_wdata = word_value;
        @(negedge clk);
        program_we = 0;
    endtask
    task automatic write_word(input [1:0] mem, input integer address, input [31:0] word_value);
        @(negedge clk);
        dma_valid = 1; dma_write = 1; dma_mem = mem;
        dma_addr = 12'(address); dma_wdata = word_value;
        #1;
        if (!dma_ready || !legacy_ready) $fatal(1, "idle write not ready");
        @(negedge clk);
        dma_valid = 0; dma_write = 0;
    endtask
    task automatic check_word(input integer address, input [31:0] expected, input bit compare_old);
        @(negedge clk);
        dma_valid = 1; dma_write = 0; dma_mem = 2; dma_addr = 12'(address);
        #1;
        // Every new request must spend one edge fetching registered RAM data.
        if (dma_ready) $fatal(1, "read ready asserted before RAM access");
        @(negedge clk);
        if (!dma_ready || dma_rdata !== expected)
            $fatal(1, "C[%0d] expected %h got %h ready=%b", address, expected, dma_rdata, dma_ready);
        if (compare_old && legacy_data !== expected)
            $fatal(1, "legacy C[%0d] expected %h got %h", address, expected, legacy_data);
        held_data = dma_rdata;
        repeat (3) begin
            @(negedge clk);
            if (!dma_ready || dma_rdata !== held_data)
                $fatal(1, "read response changed under backpressure");
        end
        dma_valid = 0;
        @(negedge clk);
    endtask
    task automatic execute;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        new_finished = 0; old_finished = 0; cycles = 0;
        while ((!new_finished || !old_finished) && cycles < 20000) begin
            @(negedge clk);
            if (done) new_finished = 1;
            if (legacy_done) old_finished = 1;
            cycles = cycles + 1;
        end
        if (!new_finished || !old_finished) $fatal(1, "engine timeout");
        if (fault !== legacy_fault || fault_code !== legacy_code || pc !== legacy_pc)
            $fatal(1, "architectural status differs");
        if (dut.writeback_valid_q) $fatal(1, "done left an uncommitted C result");
    endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        write_word(2, 0, 32'h5a5a0123);
        write_word(2, 4095, 32'h5a5a4567);
        for (test_case = 0; test_case < 32; test_case = test_case + 1) begin
            random_word = $random(seed) & 32'h7fffffff;
            m = (test_case == 0) ? 255 : 1 + (random_word % 12);
            ks = 1 + ((random_word >> 4) % 8);
            ns = 1 + ((random_word >> 8) % 8);
            lda = ks + ((random_word >> 12) % 4);
            ldb = ns + ((random_word >> 16) % 4);
            ldc = ns + ((random_word >> 20) % 4);
            if (test_case == 0) begin ks = 8; ns = 8; lda = 8; ldb = 8; ldc = 8; end
            // Zero input strides are legal and repeat stored A/B rows.
            if (test_case == 1) begin lda = 0; ldb = 0; end
            abase = 4096 - ((m-1)*lda + ks);
            bbase = 4096 - ((ks-1)*ldb + ns);
            span = (m-1)*ldc + ns;
            cbase = 4095 - span;
            for (addr = cbase; addr < cbase + span; addr = addr + 1) begin
                initial_value = 32'h7fffff80 ^ addr;
                golden[addr] = initial_value;
                write_word(2, addr, initial_value);
            end
            for (row = 0; row < m; row = row + 1)
                for (k = 0; k < ks; k = k + 1)
                    write_word(0, abase + row*lda + k, operand(abase + row*lda + k, 17));
            for (k = 0; k < ks; k = k + 1)
                for (col = 0; col < ns; col = col + 1)
                    write_word(1, bbase + k*ldb + col, operand(bbase + k*ldb + col, 91));
            for (row = 0; row < m; row = row + 1)
                for (col = 0; col < ns; col = col + 1) begin
                    dot = 0;
                    for (k = 0; k < ks; k = k + 1)
                        dot = dot + operand(abase + row*lda + k, 17) * operand(bbase + k*ldb + col, 91);
                    addr = cbase + row*ldc + col;
                    golden[addr] = ((test_case % 2) ? golden[addr] : 0) + 2*dot;
                end
            program_word(0, inst(test_case % 2));
            program_word(1, inst(1));
            program_word(2, 128'hf);
            execute();
            if (fault) $fatal(1, "valid case faulted");
            for (addr = cbase; addr < cbase + span; addr = addr + 1)
                check_word(addr, golden[addr], 1);
            check_word(0, 32'h5a5a0123, 1);
            check_word(4095, 32'h5a5a4567, 1);
        end
        // PC=255 must be fetched without truncating the full-depth IMEM.
        for (addr = 0; addr < 255; addr = addr + 1) program_word(addr, 0);
        program_word(255, 128'hf); execute();
        if (pc != 255 || fault) $fatal(1, "last instruction word failed");
        program_word(255, 0); execute();
        if (!fault || fault_code != 4) $fatal(1, "program overrun not detected");
        program_word(0, 128'h2); execute();
        if (!fault || fault_code != 1) $fatal(1, "opcode fault mismatch");
        m = 0; program_word(0, inst(0)); execute();
        if (!fault || fault_code != 2) $fatal(1, "dimension fault mismatch");
        m = 2; ks = 1; ns = 1; abase = 4095; lda = 1;
        program_word(0, inst(0)); execute();
        if (!fault || fault_code != 3) $fatal(1, "address fault mismatch");

        // Abort an active instruction with reset; RAM contents are retained.
        m = 255; ks = 8; ns = 8; abase = 0; bbase = 0; cbase = 0;
        lda = 8; ldb = 8; ldc = 8;
        program_word(0, inst(0));
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        repeat (8) @(negedge clk);
        rst_n = 0;
        repeat (3) @(negedge clk);
        if (busy || done || fault || dut.writeback_valid_q) $fatal(1, "reset did not flush control");
        rst_n = 1;
        program_word(0, 128'hf); execute();
        check_word(4095, 32'h5a5a4567, 1);

        // Reset immediately before a queued C write must suppress that write.
        m = 1; ks = 1; ns = 1; abase = 4095; bbase = 4095; cbase = 4095;
        lda = 0; ldb = 0; ldc = 0;
        program_word(0, inst(0)); program_word(1, 128'hf);
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        cycles = 0;
        while (!dut.writeback_valid_q && cycles < 1000) begin
            @(negedge clk); cycles = cycles + 1;
        end
        if (!dut.writeback_valid_q) $fatal(1, "pending writeback was not exercised");
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        check_word(4095, 32'h5a5a4567, 0);
        // Reset suppresses the pending write; a fresh start can use retained RAM.
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        cycles = 0;
        while (!done && cycles < 1000) begin @(negedge clk); cycles = cycles + 1; end
        if (!done || fault) $fatal(1, "reset/restart failed");
        check_word(4095, 32'(operand(4095,17)*operand(4095,91)), 0);

        // Selector changes at the same address invalidate an outstanding read.
        @(negedge clk); dma_valid = 1; dma_mem = 0; dma_addr = 4095;
        #1; if (dma_ready) $fatal(1, "A read accepted without clock");
        @(negedge clk);
        if (!dma_ready || $signed(dma_rdata) != operand(4095,17)) $fatal(1, "A signed read failed");
        dma_mem = 1;
        #1; if (dma_ready) $fatal(1, "selector change retained stale ready");
        @(negedge clk);
        if (!dma_ready || $signed(dma_rdata) != operand(4095,91)) $fatal(1, "B signed read failed");
        dma_valid = 0;
        // Overlapping C follows the ISA's row/column order. Compare to the
        // ordered golden calculation (legacy simultaneous writes can collide).
        m = 2; ks = 1; ns = 2; abase = 4094; bbase = 4094; cbase = 4093;
        lda = 1; ldb = 2; ldc = 1;
        write_word(0, 4094, 2); write_word(0, 4095, 3);
        write_word(1, 4094, 5); write_word(1, 4095, 7);
        program_word(0, inst(0)); program_word(1, 128'hf); execute();
        check_word(4093, 10, 0);
        check_word(4094, 15, 0);
        check_word(4095, 21, 0);
        program_word(0, inst(1)); execute();
        check_word(4093, 20, 0);
        check_word(4094, 44, 0);
        check_word(4095, 42, 0);
        $display("PASS: 32 full-depth legacy/golden comparisons, overflow, strides, guards, PC/faults, reset and read backpressure");
        $finish;
    end
endmodule
