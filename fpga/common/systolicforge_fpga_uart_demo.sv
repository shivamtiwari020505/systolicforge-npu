`timescale 1ns/1ps

module systolicforge_fpga_uart_demo #(
    parameter integer UART_CLKS_PER_BIT = 868,
    parameter integer ARRAY_ROWS        = 8,
    parameter integer ARRAY_COLS        = 8,
    parameter integer ADDR_W            = 7,
    parameter integer IMEM_DEPTH        = 16
) (
    input  logic        clk,
    input  logic        reset_button,
    input  logic        start_button,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [15:0] leds
);

    localparam integer IMEM_ADDR_W = $clog2(IMEM_DEPTH);
    localparam integer SCRATCHPAD_DEPTH = (1 << ADDR_W);

    localparam logic [7:0] CMD_PING          = 8'h00;
    localparam logic [7:0] CMD_STATUS        = 8'h01;
    localparam logic [7:0] CMD_WRITE_PROGRAM = 8'h10;
    localparam logic [7:0] CMD_WRITE_MEMORY  = 8'h11;
    localparam logic [7:0] CMD_READ_MEMORY   = 8'h12;
    localparam logic [7:0] CMD_START         = 8'h20;

    localparam logic [7:0] RESPONSE_OK          = 8'h00;
    localparam logic [7:0] RESPONSE_BUSY        = 8'h01;
    localparam logic [7:0] RESPONSE_BAD_COMMAND = 8'h02;
    localparam logic [7:0] RESPONSE_BAD_ARGUMENT = 8'h03;

    localparam logic [1:0] MEM_A = 2'd0;
    localparam logic [1:0] MEM_B = 2'd1;
    localparam logic [1:0] MEM_C = 2'd2;

    localparam logic [31:0] PROTOCOL_ID = 32'h53464e50; // "SFNP"
    localparam logic [15:0] PROTOCOL_VERSION = 16'h0001;

    typedef enum logic [3:0] {
        SELF_IDLE,
        SELF_PROGRAM_MATMUL,
        SELF_PROGRAM_HALT,
        SELF_LOAD_A,
        SELF_LOAD_B,
        SELF_START,
        SELF_WAIT,
        SELF_CHECK,
        SELF_DONE
    } self_state_t;

    logic rst_n;
    // Synchronize the board reset before it reaches RAM/DSP control state.
    // INIT holds the design in reset during the first two oscillator edges.
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_q = 2'b11;

    logic [7:0] rx_data;
    logic rx_data_valid;
    logic rx_framing_error;
    logic [7:0] tx_data;
    logic tx_data_valid;
    logic tx_data_ready;

    logic [7:0] command_q;
    logic [4:0] payload_expected_q;
    logic [4:0] payload_count_q;
    logic [135:0] payload_q;
    logic request_pending_q;

    logic response_active_q;
    logic [47:0] response_shift_q;
    logic [2:0] response_bytes_q;
    logic execute_request;
    logic [7:0] response_command;
    logic [7:0] response_status;
    logic [31:0] response_data;

    logic uart_program_we;
    logic uart_dma_valid;
    logic uart_dma_write;
    logic uart_npu_start;

    logic npu_program_we;
    logic [IMEM_ADDR_W-1:0] npu_program_addr;
    logic [127:0] npu_program_wdata;
    logic npu_dma_valid;
    logic npu_dma_ready;
    logic npu_dma_write;
    logic [1:0] npu_dma_mem;
    logic [ADDR_W-1:0] npu_dma_addr;
    logic [31:0] npu_dma_wdata;
    logic [31:0] npu_dma_rdata;
    logic npu_start;
    logic npu_busy;
    logic npu_done;
    logic npu_fault;
    logic [3:0] npu_fault_code;
    logic [IMEM_ADDR_W-1:0] npu_pc;

    (* ASYNC_REG = "TRUE" *) logic start_meta_q;
    (* ASYNC_REG = "TRUE" *) logic start_sync_q;
    logic start_prev_q;
    logic self_request_q;
    self_state_t self_state_q;
    logic [ADDR_W-1:0] self_addr_q;
    logic self_error_q;
    logic self_pass_q;
    logic self_fail_q;
    logic self_active;
    logic parser_idle;

    logic done_sticky_q;
    logic framing_error_sticky_q;
    logic command_error_sticky_q;
    logic [31:0] status_word;

    function automatic [4:0] command_payload_length(input logic [7:0] command);
        begin
            case (command)
                CMD_WRITE_PROGRAM: command_payload_length = 5'd17;
                CMD_WRITE_MEMORY:  command_payload_length = 5'd6;
                CMD_READ_MEMORY:   command_payload_length = 5'd2;
                default:           command_payload_length = 5'd0;
            endcase
        end
    endfunction

    function automatic command_is_known(input logic [7:0] command);
        begin
            case (command)
                CMD_PING,
                CMD_STATUS,
                CMD_WRITE_PROGRAM,
                CMD_WRITE_MEMORY,
                CMD_READ_MEMORY,
                CMD_START: command_is_known = 1'b1;
                default:   command_is_known = 1'b0;
            endcase
        end
    endfunction

    function automatic signed [7:0] self_diagonal_weight(input integer diagonal);
        begin
            case (diagonal)
                0: self_diagonal_weight =  8'sd1;
                1: self_diagonal_weight = -8'sd2;
                2: self_diagonal_weight =  8'sd3;
                3: self_diagonal_weight = -8'sd1;
                4: self_diagonal_weight =  8'sd2;
                5: self_diagonal_weight = -8'sd3;
                6: self_diagonal_weight =  8'sd1;
                default: self_diagonal_weight = -8'sd2;
            endcase
        end
    endfunction

    function automatic signed [31:0] self_a_value(input integer address);
        integer signed value;
        begin
            value = address - 32;
            self_a_value = value;
        end
    endfunction

    function automatic signed [31:0] self_b_value(input integer address);
        integer row;
        integer col;
        begin
            row = address / 8;
            col = address % 8;
            if (row == col)
                self_b_value = self_diagonal_weight(row);
            else
                self_b_value = 32'sd0;
        end
    endfunction

    function automatic signed [31:0] self_expected_value(input integer address);
        integer row;
        integer col;
        integer signed activation;
        integer signed weight;
        begin
            row = address / 8;
            col = address % 8;
            activation = row * 8 + col - 32;
            weight = self_diagonal_weight(col);
            self_expected_value = activation * weight;
        end
    endfunction

    always_ff @(posedge clk)
        reset_sync_q <= {reset_sync_q[0], reset_button};
    assign rst_n = !reset_sync_q[1];
    assign execute_request = request_pending_q && !response_active_q;
    assign self_active = (self_state_q != SELF_IDLE) && (self_state_q != SELF_DONE);
    assign parser_idle = (payload_expected_q == 0) && !request_pending_q &&
                         !response_active_q && tx_data_ready;

    assign tx_data = response_shift_q[7:0];
    assign tx_data_valid = response_active_q;

    always @* begin
        status_word = '0;
        status_word[0] = npu_busy;
        status_word[1] = done_sticky_q;
        status_word[2] = npu_fault;
        status_word[3] = self_active;
        status_word[4] = self_pass_q;
        status_word[5] = self_fail_q;
        status_word[6] = framing_error_sticky_q;
        status_word[7] = command_error_sticky_q;
        status_word[11:8] = npu_fault_code;
        status_word[15:12] = npu_pc;
        status_word[31:16] = PROTOCOL_VERSION;
    end

    systolicforge_uart_rx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) u_uart_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(uart_rx),
        .data(rx_data),
        .data_valid(rx_data_valid),
        .framing_error(rx_framing_error)
    );

    systolicforge_uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(tx_data),
        .data_valid(tx_data_valid),
        .data_ready(tx_data_ready),
        .tx(uart_tx)
    );

    systolicforge_fpga_engine #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DATA_W(8),
        .ACC_W(32),
        .ADDR_W(ADDR_W),
        .IMEM_DEPTH(IMEM_DEPTH),
        .INSTR_W(128)
    ) u_engine (
        .clk(clk),
        .rst_n(rst_n),
        .program_we(npu_program_we),
        .program_addr(npu_program_addr),
        .program_wdata(npu_program_wdata),
        .dma_valid(npu_dma_valid),
        .dma_ready(npu_dma_ready),
        .dma_write(npu_dma_write),
        .dma_mem(npu_dma_mem),
        .dma_addr(npu_dma_addr),
        .dma_wdata(npu_dma_wdata),
        .dma_rdata(npu_dma_rdata),
        .start(npu_start),
        .busy(npu_busy),
        .done(npu_done),
        .fault(npu_fault),
        .fault_code(npu_fault_code),
        .pc_debug(npu_pc)
    );

    always @* begin
        response_command = command_is_known(command_q) ?
                           (command_q | 8'h80) : 8'hff;
        response_status = RESPONSE_OK;
        response_data = 32'd0;
        uart_program_we = 1'b0;
        uart_dma_valid = 1'b0;
        uart_dma_write = 1'b0;
        uart_npu_start = 1'b0;

        if (execute_request) begin
            case (command_q)
                CMD_PING: response_data = PROTOCOL_ID;

                CMD_STATUS: response_data = status_word;

                CMD_WRITE_PROGRAM: begin
                    if (self_active || npu_busy) begin
                        response_status = RESPONSE_BUSY;
                    end else if (payload_q[7:0] >= IMEM_DEPTH) begin
                        response_status = RESPONSE_BAD_ARGUMENT;
                    end else begin
                        uart_program_we = 1'b1;
                    end
                end

                CMD_WRITE_MEMORY: begin
                    if (self_active || npu_busy) begin
                        response_status = RESPONSE_BUSY;
                    end else if ((payload_q[7:0] > MEM_C) ||
                                 (payload_q[15:8] >= SCRATCHPAD_DEPTH)) begin
                        response_status = RESPONSE_BAD_ARGUMENT;
                    end else begin
                        uart_dma_valid = 1'b1;
                        uart_dma_write = 1'b1;
                    end
                end

                CMD_READ_MEMORY: begin
                    if (self_active || npu_busy) begin
                        response_status = RESPONSE_BUSY;
                    end else if ((payload_q[7:0] > MEM_C) ||
                                 (payload_q[15:8] >= SCRATCHPAD_DEPTH)) begin
                        response_status = RESPONSE_BAD_ARGUMENT;
                    end else begin
                        uart_dma_valid = 1'b1;
                        response_data = npu_dma_rdata;
                    end
                end

                CMD_START: begin
                    if (self_active || npu_busy) begin
                        response_status = RESPONSE_BUSY;
                    end else begin
                        uart_npu_start = 1'b1;
                    end
                end

                default: response_status = RESPONSE_BAD_COMMAND;
            endcase
        end
    end

    always @* begin
        npu_program_we = uart_program_we;
        npu_program_addr = payload_q[IMEM_ADDR_W-1:0];
        npu_program_wdata = payload_q[135:8];
        npu_dma_valid = uart_dma_valid;
        npu_dma_write = uart_dma_write;
        npu_dma_mem = payload_q[1:0];
        npu_dma_addr = payload_q[8 +: ADDR_W];
        npu_dma_wdata = payload_q[47:16];
        npu_start = uart_npu_start;

        if (self_active) begin
            npu_program_we = 1'b0;
            npu_program_addr = '0;
            npu_program_wdata = '0;
            npu_dma_valid = 1'b0;
            npu_dma_write = 1'b0;
            npu_dma_mem = MEM_A;
            npu_dma_addr = self_addr_q;
            npu_dma_wdata = '0;
            npu_start = 1'b0;

            case (self_state_q)
                SELF_PROGRAM_MATMUL: begin
                    npu_program_we = 1'b1;
                    npu_program_addr = '0;
                    npu_program_wdata = {
                        16'd8, 16'd8, 16'd8,
                        16'd0, 16'd0, 16'd0,
                        8'd8, 8'd8, 8'd8, 4'd0, 4'h1
                    };
                end

                SELF_PROGRAM_HALT: begin
                    npu_program_we = 1'b1;
                    npu_program_addr = '0;
                    npu_program_addr[0] = 1'b1;
                    npu_program_wdata = 128'hf;
                end

                SELF_LOAD_A: begin
                    npu_dma_valid = 1'b1;
                    npu_dma_write = 1'b1;
                    npu_dma_mem = MEM_A;
                    npu_dma_wdata = self_a_value(self_addr_q);
                end

                SELF_LOAD_B: begin
                    npu_dma_valid = 1'b1;
                    npu_dma_write = 1'b1;
                    npu_dma_mem = MEM_B;
                    npu_dma_wdata = self_b_value(self_addr_q);
                end

                SELF_START: npu_start = 1'b1;

                SELF_CHECK: begin
                    npu_dma_valid = 1'b1;
                    npu_dma_mem = MEM_C;
                end

                default: begin end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            start_meta_q <= 1'b0;
            start_sync_q <= 1'b0;
            start_prev_q <= 1'b0;
            self_request_q <= 1'b0;
        end else begin
            start_meta_q <= start_button;
            start_sync_q <= start_meta_q;
            start_prev_q <= start_sync_q;

            if (start_sync_q && !start_prev_q)
                self_request_q <= 1'b1;
            if (self_request_q && parser_idle && !npu_busy)
                self_request_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            command_q <= '0;
            payload_expected_q <= '0;
            payload_count_q <= '0;
            payload_q <= '0;
            request_pending_q <= 1'b0;
            response_active_q <= 1'b0;
            response_shift_q <= '0;
            response_bytes_q <= '0;
            framing_error_sticky_q <= 1'b0;
            command_error_sticky_q <= 1'b0;
        end else begin
            if (rx_data_valid && rx_framing_error) begin
                framing_error_sticky_q <= 1'b1;
                payload_expected_q <= '0;
                payload_count_q <= '0;
            end else if (rx_data_valid) begin
                if (!request_pending_q && !response_active_q && tx_data_ready) begin
                    if (payload_expected_q == 0) begin
                        command_q <= rx_data;
                        payload_q <= '0;
                        payload_count_q <= '0;
                        payload_expected_q <= command_payload_length(rx_data);
                        if (command_payload_length(rx_data) == 0)
                            request_pending_q <= 1'b1;
                    end else begin
                        payload_q[(payload_count_q*8) +: 8] <= rx_data;
                        if (payload_count_q + 1'b1 == payload_expected_q) begin
                            payload_expected_q <= '0;
                            payload_count_q <= '0;
                            request_pending_q <= 1'b1;
                        end else begin
                            payload_count_q <= payload_count_q + 1'b1;
                        end
                    end
                end else begin
                    command_error_sticky_q <= 1'b1;
                end
            end

            if (execute_request) begin
                request_pending_q <= 1'b0;
                response_shift_q <= {
                    response_data[31:24], response_data[23:16],
                    response_data[15:8], response_data[7:0],
                    response_status, response_command
                };
                response_bytes_q <= 3'd6;
                response_active_q <= 1'b1;
                if ((response_status == RESPONSE_BAD_COMMAND) ||
                    (response_status == RESPONSE_BAD_ARGUMENT))
                    command_error_sticky_q <= 1'b1;
            end

            if (response_active_q && tx_data_ready) begin
                response_shift_q <= response_shift_q >> 8;
                response_bytes_q <= response_bytes_q - 1'b1;
                if (response_bytes_q == 3'd1)
                    response_active_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            self_state_q <= SELF_IDLE;
            self_addr_q <= '0;
            self_error_q <= 1'b0;
            self_pass_q <= 1'b0;
            self_fail_q <= 1'b0;
        end else begin
            case (self_state_q)
                SELF_IDLE,
                SELF_DONE: begin
                    if (self_request_q && parser_idle && !npu_busy) begin
                        self_addr_q <= '0;
                        self_error_q <= 1'b0;
                        self_pass_q <= 1'b0;
                        self_fail_q <= 1'b0;
                        self_state_q <= SELF_PROGRAM_MATMUL;
                    end
                end

                SELF_PROGRAM_MATMUL: self_state_q <= SELF_PROGRAM_HALT;

                SELF_PROGRAM_HALT: begin
                    self_addr_q <= '0;
                    self_state_q <= SELF_LOAD_A;
                end

                SELF_LOAD_A: begin
                    if (npu_dma_ready) begin
                        if (self_addr_q == 63) begin
                            self_addr_q <= '0;
                            self_state_q <= SELF_LOAD_B;
                        end else begin
                            self_addr_q <= self_addr_q + 1'b1;
                        end
                    end
                end

                SELF_LOAD_B: begin
                    if (npu_dma_ready) begin
                        if (self_addr_q == 63) begin
                            self_addr_q <= '0;
                            self_state_q <= SELF_START;
                        end else begin
                            self_addr_q <= self_addr_q + 1'b1;
                        end
                    end
                end

                SELF_START: self_state_q <= SELF_WAIT;

                SELF_WAIT: begin
                    if (npu_done) begin
                        self_addr_q <= '0;
                        if (npu_fault) begin
                            self_error_q <= 1'b1;
                            self_fail_q <= 1'b1;
                            self_state_q <= SELF_DONE;
                        end else begin
                            self_state_q <= SELF_CHECK;
                        end
                    end
                end

                SELF_CHECK: begin
                    if ($signed(npu_dma_rdata) != self_expected_value(self_addr_q))
                        self_error_q <= 1'b1;

                    if (self_addr_q == 63) begin
                        if (($signed(npu_dma_rdata) != self_expected_value(self_addr_q)) ||
                            self_error_q) begin
                            self_pass_q <= 1'b0;
                            self_fail_q <= 1'b1;
                        end else begin
                            self_pass_q <= 1'b1;
                            self_fail_q <= 1'b0;
                        end
                        self_state_q <= SELF_DONE;
                    end else begin
                        self_addr_q <= self_addr_q + 1'b1;
                    end
                end

                default: self_state_q <= SELF_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done_sticky_q <= 1'b0;
        end else begin
            if (npu_start)
                done_sticky_q <= 1'b0;
            if (npu_done)
                done_sticky_q <= 1'b1;
        end
    end

    always @* begin
        leds = '0;
        leds[0] = self_pass_q;
        leds[1] = self_fail_q || npu_fault;
        leds[2] = self_active || npu_busy;
        leds[3] = !parser_idle;
        leds[4] = !tx_data_ready;
        leds[5] = done_sticky_q;
        leds[6] = framing_error_sticky_q;
        leds[7] = command_error_sticky_q;
        leds[11:8] = npu_fault_code;
        leds[15:12] = npu_pc;
    end

endmodule
