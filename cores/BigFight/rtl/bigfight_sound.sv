`timescale 1ns/1ps
// Big Fight sound board glue. All timing remains in clk_sys_i; ce* are enables.
module bigfight_sound (
    input wire cyclwarr_i,
    input  wire               clk_sys_i,
    input  wire               reset_i,

    // Main-CPU command write event; accepted without backpressure outside reset.
    input  wire               command_valid_i,
    input  wire        [7:0]  command_data_i,
    output wire               command_ready_o,
    output wire               command_pending_o,
    output wire               command_overwrite_o,

    // The Z80 program region is supplied by synchronous clk_sys memory.
    output wire               audio_rom_req_o,
    output wire        [15:0] audio_rom_addr_o,
    input  wire               audio_rom_ready_i,
    input  wire               audio_rom_valid_i,
    input  wire        [7:0]  audio_rom_data_i,

    // OKI sample region is a one-outstanding, ordered response port.
    output wire               oki_rom_req_o,
    output wire        [17:0] oki_rom_addr_o,
    input  wire               oki_rom_ready_i,
    input  wire               oki_rom_valid_i,
    input  wire        [7:0]  oki_rom_data_i,

    // Framework performs final saturation. These are signed, held 18-bit values.
    output logic signed [17:0] audio_left_o,
    output logic signed [17:0] audio_right_o,
    output logic               audio_sample_valid_o,

    // Timing/service observability. Counters saturate rather than wrap.
    output logic        [31:0] z80_wait_ce_count_o,
    output logic        [31:0] audio_rom_wait_ce_count_o,
    output logic        [31:0] oki_missed_ce1_count_o,
    output logic               z80_wait_seen_o,
    output logic               oki_timing_degraded_o,

    // Observation-only enables for tests/integration diagnostics; never use as clocks.
    output wire                ce4_tick_o,
    output wire                ym_ce2_tick_o,
    output wire                oki_ce1_tick_o
);

    // 4 MHz from 50 MHz: fractional 2/25 accumulator, yielding 12/13-cycle spacing.
    logic [4:0] ce_acc_q;
    wire  [5:0] ce_acc_sum = {1'b0, ce_acc_q} + 6'd2;
    wire        ce4_tick = (ce_acc_sum >= 6'd25);
    logic       ym_half_q;
    logic [1:0] oki_div_q;
    wire        ym_ce2_tick = ce4_tick && ym_half_q;
    wire        oki_ce1_raw = ce4_tick && (cyclwarr_i ? oki_div_q[0] : (oki_div_q == 2'd3));

    assign ce4_tick_o     = ce4_tick;
    assign ym_ce2_tick_o  = ym_ce2_tick;
    assign oki_ce1_tick_o = oki_ce1_raw;

    logic [6:0] warmup_ym_edges_q;
    wire        warmup_done = (warmup_ym_edges_q == 7'd64);
    wire        chip_reset  = reset_i || !warmup_done;
    // The CPU must initialize SP/FFB8 before the first main-CPU command.
    // Only the sound chips need the shift-state warmup. Holding the Z80 too
    // delivers the deferred boot NMI before its first LD SP and corrupts boot.
    wire        z80_reset_n = !reset_i;

    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            ce_acc_q           <= 5'd0;
            ym_half_q          <= 1'b0;
            oki_div_q          <= 2'd0;
            warmup_ym_edges_q  <= 7'd0;
        end else begin
            if (ce4_tick) begin
                if (ce_acc_sum >= 6'd25)
                    ce_acc_q <= ce_acc_sum - 6'd25;
                else
                    ce_acc_q <= ce_acc_sum[4:0];
                ym_half_q <= ~ym_half_q;
                oki_div_q <= oki_div_q + 2'd1;
            end else begin
                ce_acc_q <= ce_acc_sum[4:0];
            end
            if (ym_ce2_tick && !warmup_done)
                warmup_ym_edges_q <= warmup_ym_edges_q + 7'd1;
        end
    end

    // Z80 bus and sound RAM. MAME maps 0000-DFFF ROM, E000-FFEF RAM,
    // FFF0/1 YM2151, FFF4 OKI, FFFC sound latch and FFFE write-NOP.
    wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
    wire        z80_rfsh_n, z80_halt_n, z80_busak_n;
    wire [15:0] z80_a;
    wire [7:0]  z80_dout;
    logic [7:0] z80_din;
    wire        z80_wait_n;
    wire        z80_nmi_n;
    wire        ym_irq_n;
    wire [7:0] sound_ram_data;

    wire z80_mem_cycle  = !z80_mreq_n && z80_iorq_n;
    wire z80_read_cycle = z80_mem_cycle && !z80_rd_n;
    wire z80_write_cycle = z80_mem_cycle && !z80_wr_n;
    wire z80_rom_read = z80_read_cycle && (z80_a <= 16'hdfff);
    // Read mux selects follow the stable CPU address through the CE-qualified
    // T2 sample even if tv80s has already released its registered bus strobes.
    wire z80_ram_read = (z80_a >= 16'he000) && (z80_a <= 16'hffef);
    wire z80_ym_read = (z80_a == 16'hfff0) || (z80_a == 16'hfff1);
    wire z80_oki_read = (z80_a == 16'hfff4);
    wire z80_latch_read = z80_read_cycle && (z80_a == 16'hfffc);
    wire z80_latch_addr = (z80_a == 16'hfffc);

    wire z80_ym_write_cycle = z80_write_cycle && ((z80_a == 16'hfff0) || (z80_a == 16'hfff1));
    wire z80_oki_write_cycle = z80_write_cycle && (z80_a == 16'hfff4);
    wire z80_ram_write_cycle = z80_write_cycle && (z80_a >= 16'he000) && (z80_a <= 16'hffef);

    logic        audio_rom_active_q;
    logic        audio_rom_accepted_q;
    logic        audio_rom_data_valid_q;
    logic [15:0] audio_rom_addr_q;
    logic [7:0]  audio_rom_data_q;

    assign audio_rom_req_o = z80_rom_read && !audio_rom_accepted_q && !audio_rom_data_valid_q;
    assign audio_rom_addr_o = audio_rom_active_q ? audio_rom_addr_q : z80_a;

    logic [7:0] sound_command_q;
    logic       command_pending_q;
    logic       nmi_pending_q;
    logic       nmi_deferred_q;
    logic       nmi_pending_d;
    logic       nmi_deferred_d;
    logic       command_overwrite_q;
    logic       latch_read_seen_q;
    logic       ram_write_seen_q;
    logic       device_write_done_q;
    wire ram_write_commit = !reset_i && z80_ram_write_cycle && !ram_write_seen_q;
    bigfight_sound_ram u_sound_ram (
        .clk_sys(clk_sys_i),
        .read_enable(!reset_i && z80_ram_read),
        .write_enable(ram_write_commit),
        .address(z80_a[12:0]),.write_data(z80_dout),.read_data(sound_ram_data)
    );

    assign command_ready_o = !reset_i;
    assign command_pending_o = command_pending_q;
    assign command_overwrite_o = command_overwrite_q;
    assign z80_nmi_n = !nmi_pending_q;

    // One edge-triggered event is held for sampling by the CE4-driven CPU.
    // Repeated writes while the stretched pulse is low coalesce, matching the
    // Z80's single pending-NMI bit; the separate data latch still keeps latest.
    always_comb begin
        nmi_pending_d = nmi_pending_q;
        nmi_deferred_d = nmi_deferred_q;
        if (ce4_tick && warmup_done) begin
            if (nmi_pending_q)
                nmi_pending_d = 1'b0;
            else if (nmi_deferred_q) begin
                nmi_pending_d = 1'b1;
                nmi_deferred_d = 1'b0;
            end
        end
        if (command_valid_i && command_ready_o) begin
            if (!warmup_done)
                nmi_deferred_d = 1'b1;
            else if (!nmi_pending_q && !nmi_deferred_q)
                nmi_pending_d = 1'b1;
        end
    end

    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            nmi_pending_q <= 1'b0;
            nmi_deferred_q <= 1'b0;
        end else begin
            nmi_pending_q <= nmi_pending_d;
            nmi_deferred_q <= nmi_deferred_d;
        end
    end

    logic [7:0] ym_dout;
    logic signed [15:0] ym_left, ym_right;
    wire ym_sample;
    logic [7:0] oki_dout;
    logic signed [13:0] oki_sound;
    wire oki_sample;
    wire [17:0] oki_addr;

    logic oki_cache_valid_q;
    logic oki_req_accepted_q;
    logic [17:0] oki_req_addr_q;
    logic [17:0] oki_cache_addr_q;
    logic [7:0]  oki_cache_data_q;
    wire oki_cached_hit = oki_cache_valid_q && (oki_cache_addr_q == oki_addr);
    wire oki_response_hit = oki_rom_valid_i && oki_req_accepted_q && (oki_req_addr_q == oki_addr);
    wire oki_cache_hit = oki_cached_hit || oki_response_hit;
    wire [7:0] oki_rom_data = oki_response_hit ? oki_rom_data_i : oki_cache_data_q;
    // Cycle Warriors keeps the actual 2MHz oscillator running. ROM readiness
    // qualifies the donor's control interface; its ADPCM deadline is observed
    // separately. Preserve the already qualified Big Fight scheduling profile.
    wire oki_ce1_tick = oki_ce1_raw && (cyclwarr_i || oki_cache_hit);
    wire oki_rom_deadline_miss;
    wire oki_write_tick = !chip_reset && oki_ce1_tick && z80_oki_write_cycle && !device_write_done_q;

    assign oki_rom_req_o = !reset_i && !oki_cache_hit && !oki_req_accepted_q;
    assign oki_rom_addr_o = oki_req_accepted_q ? oki_req_addr_q : oki_addr;

    // A cache miss holds the chip's native enable until the matching byte arrives.
    // Bypass a matching response into that same cycle: registering it first would
    // withhold a native enable even though the requested byte is already present.
    jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_oki (
        .rst(chip_reset), .clk(clk_sys_i), .cen(oki_ce1_tick), .ss(1'b1),
        .wrn(!oki_write_tick),
        .din(z80_dout), .dout(oki_dout),
        .rom_addr(oki_addr), .rom_data(oki_rom_data), .rom_ok(oki_cache_hit),
        .rom_deadline_miss(oki_rom_deadline_miss),
        .sound(oki_sound), .sample(oki_sample)
    );

    // Keep an early CPU write in WAIT until the receiving chip leaves reset.
    // JT51's busy flag accepts data writes on cen_p1. A one-root pulse on
    // the other CE4 half writes registers but loses busy, failing ROM self-test.
    wire ym_write_tick = !chip_reset && ym_ce2_tick && z80_ym_write_cycle && !device_write_done_q;
    jt51 u_ym (
        .rst(chip_reset), .clk(clk_sys_i), .cen(ce4_tick), .cen_p1(ym_ce2_tick),
        .cs_n(!ym_write_tick), .wr_n(!ym_write_tick), .a0(z80_a[0]), .din(z80_dout),
        .dout(ym_dout), .ct1(), .ct2(), .irq_n(ym_irq_n), .sample(ym_sample),
        .left(ym_left), .right(ym_right), .xleft(), .xright()
    );

    // Assert writes from T1 so the device wait is visible before the core's
    // enabled T2 edge. The CE-qualified wrapper holds pins between enables.
    tv80s_ce #(.Mode(0), .T2Write(1), .IOWait(1)) u_z80 (
        .reset_n(z80_reset_n), .clk(clk_sys_i), .cen(ce4_tick), .wait_n(z80_wait_n),
        .int_n(ym_irq_n), .nmi_n(z80_nmi_n), .busrq_n(1'b1),
        .read_t2(), .m1_n(z80_m1_n), .mreq_n(z80_mreq_n), .iorq_n(z80_iorq_n),
        .rd_n(z80_rd_n), .wr_n(z80_wr_n), .rfsh_n(z80_rfsh_n),
        .halt_n(z80_halt_n), .busak_n(z80_busak_n), .A(z80_a), .di(z80_din), .dout(z80_dout)
    );

    always_comb begin
        z80_din = 8'hff;
        // Retain the accepted byte through the CE-qualified T2 consumer edge.
        // The CE wrapper holds bus strobes between CPU enables.
        if (z80_rom_read || audio_rom_active_q)
            z80_din = audio_rom_data_valid_q ? audio_rom_data_q : 8'hff;
        else if (z80_ram_read)
            z80_din = sound_ram_data;
        else if (z80_ym_read)
            z80_din = ym_dout;
        else if (z80_oki_read)
            z80_din = ~oki_dout; // MAME's oki_status_xor_r() reverses all status bits.
        else if (z80_latch_addr)
            z80_din = sound_command_q;
    end

    assign z80_wait_n = !(z80_rom_read && !audio_rom_data_valid_q) &&
                        !(z80_ym_write_cycle && !device_write_done_q) &&
                        !(z80_oki_write_cycle && !device_write_done_q);

    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            audio_rom_active_q     <= 1'b0;
            audio_rom_accepted_q   <= 1'b0;
            audio_rom_data_valid_q <= 1'b0;
            audio_rom_addr_q       <= 16'd0;
            audio_rom_data_q       <= 8'd0;
        end else begin
            if (!audio_rom_active_q && z80_rom_read) begin
                audio_rom_active_q <= 1'b1;
                audio_rom_addr_q   <= z80_a;
            end
            if (audio_rom_req_o && audio_rom_ready_i) begin
                audio_rom_accepted_q <= 1'b1;
                audio_rom_addr_q     <= audio_rom_addr_o;
            end
            if (audio_rom_valid_i && audio_rom_active_q) begin
                audio_rom_data_q       <= audio_rom_data_i;
                audio_rom_data_valid_q <= 1'b1;
                audio_rom_accepted_q   <= 1'b0;
            end
            // Retire after the CE-qualified wrapper has released the read pins;
            // the consumed reply remains stable through its T2 capture.
            if (audio_rom_active_q && audio_rom_data_valid_q && ce4_tick && !z80_rom_read) begin
                audio_rom_active_q     <= 1'b0;
                audio_rom_accepted_q   <= 1'b0;
                audio_rom_data_valid_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            oki_cache_valid_q   <= 1'b0;
            oki_req_accepted_q  <= 1'b0;
            oki_req_addr_q      <= 18'd0;
            oki_cache_addr_q    <= 18'd0;
            oki_cache_data_q    <= 8'd0;
        end else begin
            if (oki_rom_req_o && oki_rom_ready_i) begin
                oki_req_accepted_q <= 1'b1;
                oki_req_addr_q     <= oki_rom_addr_o;
            end
            if (oki_rom_valid_i) begin
                oki_cache_valid_q  <= 1'b1;
                oki_req_accepted_q <= 1'b0;
                oki_cache_addr_q   <= oki_req_accepted_q ? oki_req_addr_q : oki_rom_addr_o;
                oki_cache_data_q   <= oki_rom_data_i;
            end
        end
    end

    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            sound_command_q       <= 8'h00;
            command_pending_q     <= 1'b0;
            command_overwrite_q   <= 1'b0;
            latch_read_seen_q     <= 1'b0;
            ram_write_seen_q      <= 1'b0;
            device_write_done_q   <= 1'b0;
        end else begin
            if (command_valid_i && command_ready_o) begin
                if (command_pending_q)
                    command_overwrite_q <= 1'b1;
                sound_command_q   <= command_data_i;
                command_pending_q <= 1'b1;
            end else if (z80_latch_read && !latch_read_seen_q) begin
                command_pending_q <= 1'b0;
            end

            if (!z80_latch_read)
                latch_read_seen_q <= 1'b0;
            else
                latch_read_seen_q <= 1'b1;

            if (!z80_ram_write_cycle)
                ram_write_seen_q <= 1'b0;
            else if (!ram_write_seen_q) begin
                ram_write_seen_q <= 1'b1;
            end

            if (!z80_ym_write_cycle && !z80_oki_write_cycle)
                device_write_done_q <= 1'b0;
            else if (ym_write_tick || oki_write_tick)
                device_write_done_q <= 1'b1;
        end
    end

    // Count every 4 MHz enable for which Z80 WAIT is active and every raw 1 MHz
    // OKI enable withheld by a missing ROM byte. Neither metric wraps.
    always_ff @(posedge clk_sys_i) begin
        if (reset_i) begin
            z80_wait_ce_count_o   <= 32'd0;
            audio_rom_wait_ce_count_o <= 32'd0;
            oki_missed_ce1_count_o <= 32'd0;
            z80_wait_seen_o       <= 1'b0;
            oki_timing_degraded_o <= 1'b0;
        end else if (warmup_done) begin
            if (ce4_tick && !z80_wait_n) begin
                if (z80_wait_ce_count_o != 32'hffff_ffff)
                    z80_wait_ce_count_o <= z80_wait_ce_count_o + 32'd1;
                z80_wait_seen_o <= 1'b1;
            end
            if (ce4_tick && z80_rom_read && !audio_rom_data_valid_q) begin
                if (audio_rom_wait_ce_count_o != 32'hffff_ffff)
                    audio_rom_wait_ce_count_o <= audio_rom_wait_ce_count_o + 32'd1;
            end
            if (cyclwarr_i ? oki_rom_deadline_miss : (oki_ce1_raw && !oki_cache_hit)) begin
                if (oki_missed_ce1_count_o != 32'hffff_ffff)
                    oki_missed_ce1_count_o <= oki_missed_ce1_count_o + 32'd1;
                oki_timing_degraded_o <= 1'b1;
            end
        end
    end

    // MAME routing: YM L/R x 0.45 and mono OKI x 0.75 to both speakers.
    // Raw OKI counts use MAME's 2048 denominator, YM uses 32768.
    // The board mixer normalizes before applying the exact rational routes.
    logic signed [15:0] ym_left_hold_q, ym_right_hold_q;
    logic ym_first_boundary_seen_q;
    logic signed [13:0] oki_hold_q;
    // Independent 48kHz output cadence, unaffected by sample-ROM backpressure.
    logic [12:0] output_acc_q;
    wire [13:0] output_sum={1'b0,output_acc_q}+14'd6;
    wire output_tick=(output_sum>=14'd6250);
    logic ym_native_valid_q,oki_native_valid_q,oki_resample_valid_q;
    wire signed [15:0] fm_left,fm_right;
    wire signed [13:0] oki_filtered;
    wire fm_valid,oki_valid;
    bigfight_audio_resample #(.WIDTH(16),.PERIOD(800),.FM(1)) fm_resample(.fast_i(1'b0),
        .clk(clk_sys_i),.reset(chip_reset),.sample_i(ym_native_valid_q),
        .output_tick(output_tick),.left_i(ym_left_hold_q),.right_i(ym_right_hold_q),
        .left_o(fm_left),.right_o(fm_right),.valid_o(fm_valid));
    bigfight_audio_resample #(.WIDTH(14),.PERIOD(6600),.FM(0)) oki_resample(.fast_i(cyclwarr_i),
        .clk(clk_sys_i),.reset(chip_reset),.sample_i(oki_resample_valid_q),
        .output_tick(output_tick),.left_i(oki_hold_q),.right_i(oki_hold_q),
        .left_o(oki_filtered),.right_o(),.valid_o(oki_valid));
    wire signed [17:0] mixed_left,mixed_right;
    bigfight_sound_mix mix(.ym_left(fm_left),.ym_right(fm_right),
        .oki_mono(oki_filtered),.mixed_left(mixed_left),.mixed_right(mixed_right));

    always_ff @(posedge clk_sys_i) begin
        if (chip_reset) begin
            output_acc_q        <= 13'd0;
            ym_native_valid_q   <= 1'b0;
            oki_native_valid_q  <= 1'b0;
            oki_resample_valid_q <= 1'b0;
            ym_first_boundary_seen_q <= 1'b0;
            ym_left_hold_q       <= 16'sd0;
            ym_right_hold_q      <= 16'sd0;
            oki_hold_q           <= 14'sd0;
            audio_left_o         <= 18'sd0;
            audio_right_o        <= 18'sd0;
            audio_sample_valid_o <= 1'b0;
        end else begin
            output_acc_q <= output_tick ? output_sum-14'd6250 : output_sum[12:0];
            ym_native_valid_q <= ym_sample && ym_first_boundary_seen_q;
            // The accumulator publishes its new OKI sum on the sample edge.
            // Capture it one clock later; the resampler consumes the stable hold.
            oki_native_valid_q <= oki_sample;
            oki_resample_valid_q <= oki_native_valid_q;
            audio_sample_valid_o <= 1'b0;
            if (ym_sample) begin
                // JT51 cur resets to0: the first C1 interval publishes an
                // uninitialized pre-sum before the first C2 accumulation.
                // The second zero/sample follows a complete C2→C1 interval.
                // Discard exactly the first post-reset FM output boundary.
                ym_first_boundary_seen_q <= 1'b1;
                if (ym_first_boundary_seen_q) begin
                    ym_left_hold_q  <= ym_left;
                    ym_right_hold_q <= ym_right;
                end
            end
            if (oki_native_valid_q) oki_hold_q <= oki_sound;
            if (fm_valid && oki_valid) begin
                audio_left_o         <= mixed_left[17:0];
                audio_right_o        <= mixed_right[17:0];
                audio_sample_valid_o <= 1'b1;
            end
        end
    end

endmodule
