// SPDX-License-Identifier: GPL-3.0-or-later
// T5182 address decode and handshake around the same T80 export as the main CPU.
// The actual internal/external firmware is supplied by the ROM service.
module darkmist_t5182 (
    input wire clk, reset, cpu_cen, ym_cen, ym_cen_p1, pause,
    input wire [1:0] coins,
    input wire [6:0] host_addr,
    input wire [7:0] host_dout,
    output reg [7:0] host_din,
    input wire host_write, host_irq, main_sem_acquire, main_sem_release,
    output reg sound_semaphore,
    output wire rom_req, rom_external,
    output wire [14:0] rom_addr,
    input wire rom_valid,
    input wire [7:0] rom_data,
    output wire signed [15:0] audio_left, audio_right,
    output wire audio_sample,
    output wire [15:0] cpu_addr,
    output reg trace_write,
    output reg trace_io,
    output reg [15:0] trace_addr,
    output reg [7:0] trace_data,
    output reg [2:0] irq_state,
    output reg [7:0] unknown_port40, unknown_port50,
    output wire debug_io_read, debug_irq_ack, debug_fetch,
    output wire [7:0] debug_din
);
    // JT51's distributed CSR reset masks its outputs and requires enabled
    // clocks to flush the stored envelope/state. Guarantee 64 master edges
    // even for a one-edge incoming reset, independently of pause.
    reg [5:0] jt51_reset_left;
    always @(posedge clk) begin
        if (reset) jt51_reset_left <= 6'd63;
        else if (jt51_reset_left != 6'd0)
            jt51_reset_left <= jt51_reset_left - 6'd1;
    end
    wire sound_reset = reset || (jt51_reset_left != 6'd0);
    wire [7:0] cpu_dout;
    reg [7:0] cpu_din;
    wire m1_n, mreq_n, iorq_n, rd_n, wr_n;
    wire unused_rfsh, unused_halt, unused_busak;
    wire memory_read = !mreq_n && !rd_n;
    wire memory_write = !mreq_n && !wr_n;
    wire io_read = !iorq_n && !rd_n;
    wire io_write = !iorq_n && !wr_n;
    assign debug_io_read = io_read;
    assign debug_irq_ack = !m1_n && !iorq_n;
    assign debug_fetch = memory_read && !m1_n;
    assign debug_din = cpu_din;
    reg write_seen;
    wire write_once = (memory_write || io_write) && !write_seen && !sound_reset;
    wire rom_read = memory_read && (cpu_addr < 16'h2000 || cpu_addr >= 16'h8000);
    reg response_ready;
    reg [7:0] response_data;
    assign rom_req = rom_read && !response_ready && !sound_reset;
    assign rom_external = cpu_addr[15];
    assign rom_addr = cpu_addr[14:0];

    T80s cpu (
        .RESET_n(!sound_reset), .CLK(clk), .CEN(cpu_cen && !pause),
        .WAIT_n(!rom_read || response_ready), .INT_n(!( |irq_state)),
        .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(cpu_din),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(unused_rfsh),
        .HALT_n(unused_halt), .BUSAK_n(unused_busak),
        .A(cpu_addr), .DOUT(cpu_dout)
    );

    reg [7:0] internal_ram[0:2047];
    reg [7:0] shared_ram[0:255];
    reg [7:0] internal_read, shared_read;
    // Both physical access ports share one clock; 128 bytes exposed to the host.
    always @(posedge clk) begin
        internal_read <= internal_ram[cpu_addr[10:0]];
        shared_read <= shared_ram[cpu_addr[7:0]];
        if (!reset && write_once && memory_write) begin
            if (cpu_addr >= 16'h2000 && cpu_addr < 16'h4000)
                internal_ram[cpu_addr[10:0]] <= cpu_dout;
            // Same-clock same-index collision: the host write wins (one driver per clock).
            if (cpu_addr >= 16'h4000 && cpu_addr < 16'h8000 &&
                !(!reset && host_write && {1'b0,host_addr} == cpu_addr[7:0]))
                shared_ram[cpu_addr[7:0]] <= cpu_dout;
        end
    end
    always @(posedge clk) begin
        host_din <= shared_ram[{1'b0,host_addr}];
        if (!reset && host_write) shared_ram[{1'b0,host_addr}] <= host_dout;
    end

    wire [7:0] ym_data;
    wire ym_sample_raw;
    wire signed [15:0] ym_left_raw, ym_right_raw;
    reg ym_output_valid;
    // The accumulator's output latch is not reset by JT51. Discard its first
    // round strobe after reset; subsequent strobes carry freshly accumulated PCM.
    always @(posedge clk) begin
        if (sound_reset) ym_output_valid <= 1'b0;
        else if (ym_sample_raw) ym_output_valid <= 1'b1;
    end
    assign audio_sample = ym_sample_raw && ym_output_valid;
    assign audio_left = ym_output_valid ? ym_left_raw : 16'sd0;
    assign audio_right = ym_output_valid ? ym_right_raw : 16'sd0;
    wire ym_irq_n;
    wire unused_ct1, unused_ct2;
    wire signed [15:0] unused_xleft, unused_xright;
    // M1 must be high: M1 low with IORQ low is interrupt acknowledge, not a YM access.
    wire ym_select = !sound_reset && !iorq_n && m1_n && cpu_addr[7:1] == 7'd0;
    jt51 ym (
        .rst(sound_reset), .clk(clk), .cen((ym_cen && !pause) || sound_reset),
        .cen_p1((ym_cen_p1 && !pause) || sound_reset), .cs_n(!ym_select),
        .wr_n(wr_n), .a0(cpu_addr[0]), .din(cpu_dout), .dout(ym_data),
        .ct1(unused_ct1), .ct2(unused_ct2), .irq_n(ym_irq_n),
        .sample(ym_sample_raw), .left(ym_left_raw), .right(ym_right_raw),
        .xleft(unused_xleft), .xright(unused_xright)
    );

    // YM status busy bit. MAME arms a 64-clock (17.88 us) busy window at the data-write tap and reports busy to
    // a status read whose tap is earlier than the window end (a read exactly 64 T-states later sees "ready").
    // Every Z80 read lands an integer number of T-states after the write, and this bus samples 0.54 us (26.5 clk)
    // after the MAME tap, so the window end is placed midway between the 63-T and 64-T read positions:
    // 63.5 T + 0.54 us = 898.4 clk after the trace instant. The jt51 busy bit (cen_p1 steps) is not used.
    localparam [9:0] YM_BUSY_CLKS = 10'd899;
    reg [9:0] ym_busy_left;
    always @(posedge clk) begin
        if (reset) ym_busy_left <= 10'd0;
        else if (write_once && io_write && cpu_addr[7:0] == 8'h01) ym_busy_left <= YM_BUSY_CLKS;
        else if (ym_busy_left != 10'd0 && !pause) ym_busy_left <= ym_busy_left - 10'd1;
    end

    reg main_semaphore, ym_irq_previous;
    reg [2:0] next_irq;
    always @* begin
        next_irq = irq_state;
        if (write_once && io_write && cpu_addr[7:0] == 8'h12) next_irq[2] = 1'b0;
        if (write_once && io_write && cpu_addr[7:0] == 8'h13) next_irq[1] = 1'b0;
        // YM's callback changes the level bit and latches its request on assertion.
        if (ym_irq_n && ym_irq_previous) next_irq[0] = 1'b0;
        if (!ym_irq_n && !ym_irq_previous) begin
            next_irq[0] = 1'b1;
            next_irq[2] = 1'b1;
        end
        if (host_irq) next_irq[1] = 1'b1;
    end
    always @* begin
        cpu_din = 8'hff;
        if (memory_read) begin
            if (rom_read) cpu_din = response_data;
            else if (cpu_addr < 16'h4000) cpu_din = internal_read;
            else cpu_din = shared_read;
        end
        if (io_read) begin
            case (cpu_addr[7:0])
                8'h00,8'h01: cpu_din = {ym_busy_left != 10'd0, ym_data[6:0]};
                8'h20: cpu_din = {6'd0,irq_state[1],main_semaphore};
                8'h30: cpu_din = {6'd0,coins};
                default: cpu_din = 8'hff;
            endcase
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            write_seen <= 1'b0;
            response_ready <= 1'b0;
            response_data <= 8'hff;
            irq_state <= 3'd0;
            ym_irq_previous <= 1'b0;
            main_semaphore <= 1'b0;
            sound_semaphore <= 1'b0;
            trace_write <= 1'b0;
            trace_io <= 1'b0;
            trace_addr <= 16'd0;
            trace_data <= 8'd0;
            unknown_port40 <= 8'd0;
            unknown_port50 <= 8'd0;
        end else begin
            irq_state <= next_irq;
            ym_irq_previous <= !ym_irq_n;
            if (main_sem_acquire) main_semaphore <= 1'b1;
            if (main_sem_release) main_semaphore <= 1'b0;
            if (sound_reset || !(memory_write || io_write)) write_seen <= 1'b0;
            if (write_once) write_seen <= 1'b1;
            if (sound_reset || !rom_read) response_ready <= 1'b0;
            else if (rom_valid) begin
                response_ready <= 1'b1;
                response_data <= rom_data;
            end
            trace_write <= write_once;
            trace_io <= write_once && io_write;
            if (write_once) begin
                trace_addr <= cpu_addr;
                trace_data <= cpu_dout;
                if (io_write) begin
                    case (cpu_addr[7:0])
                        8'h10: sound_semaphore <= 1'b1;
                        8'h11: sound_semaphore <= 1'b0;
                        // Observe these undocumented ports; do not invent functions.
                        8'h40: unknown_port40 <= cpu_dout;
                        8'h50: unknown_port50 <= cpu_dout;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
