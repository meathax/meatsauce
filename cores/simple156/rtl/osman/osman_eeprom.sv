// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 OSMAN FPGA contributors.
// Behaviour follows MAME 0.289 eepromser.cpp/eeprom.cpp (Aaron Giles,
// BSD-3-Clause). New RTL; no Night Slashers seed or protocol code copied.
// See docs/EEPROM.md for provenance, timing and persistence contract.
module osman_eeprom #(
    parameter integer WRITE_CYCLE_CLKS = 84000,
    parameter integer ERASE_CYCLE_CLKS = 48000,
    parameter integer BULK_CYCLE_CLKS = 384000
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        cs,
    input  wire        sk,
    input  wire        di,
    output wire        do_out,
    output wire        busy,
    input  wire        load_en,
    input  wire [5:0]  load_addr,
    input  wire [15:0] load_data,
    input  wire [5:0]  state_addr,
    output reg  [15:0] state_data
);
    localparam integer MAX_CYCLE_CLKS = (WRITE_CYCLE_CLKS > ERASE_CYCLE_CLKS)
        ? ((WRITE_CYCLE_CLKS > BULK_CYCLE_CLKS) ? WRITE_CYCLE_CLKS : BULK_CYCLE_CLKS)
        : ((ERASE_CYCLE_CLKS > BULK_CYCLE_CLKS) ? ERASE_CYCLE_CLKS : BULK_CYCLE_CLKS);
    localparam integer TIMER_WIDTH = (MAX_CYCLE_CLKS < 2) ? 1 : $clog2(MAX_CYCLE_CLKS + 1);
    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_COMMAND = 3'd2,
        S_READ = 3'd3, S_WRITE = 3'd4, S_COMPLETE = 3'd5;

    // Persistent contents have neither a reset assignment nor a synthetic seed.
    // Integration MUST load all 64 words before releasing protocol/CPU reset.
    // Two block-RAM copies written together: one serves the serial/bulk logic,
    // the other the passive host read port. A word is read synchronously, one
    // clock after its address is presented (rd_data); address is set at least
    // one SK period before the first data edge, and bulk operations run at one
    // word per two clocks (the timer covers the 128 clocks).
    (* ramstyle = "M10K" *) reg [15:0] mem [0:63];
    (* ramstyle = "M10K" *) reg [15:0] mem_host [0:63];
    reg [15:0] rd_data;
    reg bulk_phase;
    reg cmd_we;
    reg [5:0] cmd_addr;
    reg [15:0] cmd_data;
    reg [2:0] state;
    reg cs_prev, sk_prev, write_enable, write_all;
    reg [7:0] command_shift;
    reg [4:0] bit_count;
    reg [5:0] address;
    reg [15:0] data_shift;
    reg serial_do;
    reg [TIMER_WIDTH-1:0] busy_count;
    reg bulk_active, bulk_erase;
    reg [5:0] bulk_addr;
    reg [15:0] bulk_data;

    assign busy = (busy_count != 0) || bulk_active;
    // MAME 93Cxx multiplexes ready/busy only in WAIT_FOR_START_BIT.
    // CS low and all other inactive states model the board's DO pull-up.
    assign do_out = !cs ? 1'b1 : ((state == S_READ) ? serial_do
        : ((state == S_START) ? !busy : 1'b1));

    // Single write port: integration load, then bulk step, then a command write.
    wire bulk_write = bulk_active && bulk_phase && !load_en;
    wire wr_en = load_en || (!reset && (bulk_write || cmd_we));
    wire [5:0] wr_addr = load_en ? load_addr : bulk_write ? bulk_addr : cmd_addr;
    wire [15:0] wr_data = load_en ? load_data
        : bulk_write ? (bulk_erase ? 16'hffff : (rd_data & bulk_data)) : cmd_data;
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
            mem_host[wr_addr] <= wr_data;
        end
    end

    always @(posedge clk) begin
        // Passive host read has one-clock latency and old-data semantics on a
        // same-address simultaneous write. Neither host port resets EEPROM data.
        state_data <= mem_host[state_addr];
        rd_data <= mem[bulk_active ? bulk_addr : address];

        cs_prev <= cs;
        sk_prev <= sk;
        if (reset) begin
            state <= S_IDLE;
            write_enable <= 1'b0;
            write_all <= 1'b0;
            command_shift <= 0;
            bit_count <= 0;
            address <= 0;
            data_shift <= 0;
            serial_do <= 1'b1;
            busy_count <= 0;
            bulk_active <= 1'b0;
            bulk_erase <= 1'b0;
            bulk_addr <= 0;
            bulk_data <= 0;
            bulk_phase <= 1'b0;
            cmd_we <= 1'b0;
            cmd_addr <= 0;
            cmd_data <= 0;
        end else begin
            cmd_we <= 1'b0;
            if (busy_count != 0)
                busy_count <= busy_count - 1'b1;
            // Bulk operations use one word per clk, rather than 64 write ports.
            // The timer covers this work; BULK_CYCLE_CLKS must be at least 128 (one word per two clocks).
            if (bulk_active && !load_en) begin
                if (!bulk_phase)
                    bulk_phase <= 1'b1;     // read issued this clock
                else begin
                    bulk_phase <= 1'b0;     // write of the word read last clock
                    if (bulk_addr == 6'd63)
                        bulk_active <= 1'b0;
                    else
                        bulk_addr <= bulk_addr + 1'b1;
                end
            end

            if (!cs) begin
                state <= S_IDLE;
                serial_do <= 1'b1;
            end else if (!cs_prev) begin
                // A coincident rising CS/SK edge is not a start bit (MAME).
                state <= S_START;
                serial_do <= 1'b1;
            end else if (sk && !sk_prev && !load_en) begin
                case (state)
                    S_START: if (di && !busy) begin
                        state <= S_COMMAND;
                        command_shift <= 0;
                        bit_count <= 0;
                    end
                    S_COMMAND: begin
                        command_shift <= {command_shift[6:0], di};
                        if (bit_count == 5'd7) begin
                            address <= {command_shift[4:0], di};
                            bit_count <= 0;
                            case (command_shift[6:5])
                                2'b10: begin
                                    state <= S_READ;
                                    // Dummy zero appears immediately after the
                                    // final address edge, before the first data edge.
                                    serial_do <= 1'b0;
                                end
                                2'b01: begin
                                    state <= S_WRITE;
                                    write_all <= 1'b0;
                                    data_shift <= 0;
                                end
                                2'b11: begin
                                    state <= S_COMPLETE;
                                    if (write_enable) begin
                                        cmd_we <= 1'b1;
                                        cmd_addr <= {command_shift[4:0], di};
                                        cmd_data <= 16'hffff;
                                        busy_count <= TIMER_WIDTH'(ERASE_CYCLE_CLKS);
                                    end
                                end
                                2'b00: case (command_shift[4:3])
                                    2'b00: begin // EWDS
                                        write_enable <= 1'b0;
                                        state <= S_COMPLETE;
                                    end
                                    2'b11: begin // EWEN
                                        write_enable <= 1'b1;
                                        state <= S_COMPLETE;
                                    end
                                    2'b01: begin // WRAL
                                        state <= S_WRITE;
                                        write_all <= 1'b1;
                                        data_shift <= 0;
                                    end
                                    2'b10: begin // ERAL
                                        state <= S_COMPLETE;
                                        if (write_enable) begin
                                            bulk_active <= 1'b1;
                                            bulk_erase <= 1'b1;
                                            bulk_addr <= 0;
                                            busy_count <= TIMER_WIDTH'(BULK_CYCLE_CLKS);
                                        end
                                    end
                                endcase
                            endcase
                        end else
                            bit_count <= bit_count + 1'b1;
                    end
                    S_READ: begin
                        // Standard MAME 93C46 is non-streaming: after 16 data
                        // bits, DO stays high until CS drops. Rising SK shifts.
                        if (bit_count == 0) begin
                            serial_do <= rd_data[15];
                            data_shift <= {rd_data[14:0], 1'b1};
                            bit_count <= 1;
                        end else if (bit_count < 5'd16) begin
                            serial_do <= data_shift[15];
                            data_shift <= {data_shift[14:0], 1'b1};
                            bit_count <= bit_count + 1'b1;
                        end else
                            serial_do <= 1'b1;
                    end
                    S_WRITE: begin
                        data_shift <= {data_shift[14:0], di};
                        if (bit_count == 5'd15) begin
                            state <= S_COMPLETE;
                            if (write_enable) begin
                                if (write_all) begin
                                    bulk_active <= 1'b1;
                                    bulk_erase <= 1'b0;
                                    bulk_addr <= 0;
                                    bulk_data <= {data_shift[14:0], di};
                                    busy_count <= TIMER_WIDTH'(BULK_CYCLE_CLKS);
                                end else begin
                                    cmd_we <= 1'b1;
                                    cmd_addr <= address;
                                    cmd_data <= {data_shift[14:0], di};
                                    busy_count <= TIMER_WIDTH'(WRITE_CYCLE_CLKS);
                                end
                            end
                        end else
                            bit_count <= bit_count + 1'b1;
                    end
                    default: begin end // Completion requires a fresh CS edge.
                endcase
            end
        end
    end
endmodule
