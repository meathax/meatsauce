// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
// Zero Team USA adaptation: exact MAME map, 96 MHz enables, plain ROM, TV80.
// Normal Seibu latch/IRQ logic derived from Arcade-Raiden_MiSTer,
// commit 28cd62a632f8a5c12dfc81e0882b9869ac57940d.
// No sound savestates are implemented. ROM download is raw 64 KiB LE words.
module ZeroTeam_audio #(parameter [26:0] ROM_BASE=27'h0a0000) (
    input wire clk,reset,pause,
    input wire ioctl_download,ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_dout,
    input wire snd_cs,snd_wr,snd_rd,
    input wire [2:0] snd_addr,
    input wire [15:0] snd_wdata,
    output wire [15:0] snd_rdata,
    input wire [7:0] coin_input,
    output wire [17:0] oki_rom_addr,
    input wire [7:0] oki_rom_data,
    input wire oki_rom_ok,
    output reg signed [15:0] audio_l,audio_r,
    output wire audio_sample,
    // The same mono mix resampled to exactly 48 kHz (what the MiSTer audio
    // block samples); audio_l/r above stay at the native 49.716 kHz FM rate.
    output wire signed [15:0] out_l,out_r,
    output wire out_sample,
    output wire [15:0] debug_address,
    output wire [7:0] debug_data,debug_din,
    output wire debug_read,debug_write,debug_fetch,debug_iack,
    output wire debug_cen,debug_ym_irq,debug_pending
);
    // 96 MHz * 105/2816 = 3.579545 MHz; *15/1408 = 1.022727 MHz.
    reg [11:0] z_acc=0;
    reg [10:0] o_acc=0;
    wire [12:0] z_next = {1'b0,z_acc}+13'd105;
    wire [11:0] o_next = {1'b0,o_acc}+12'd15;
    wire cen_z80 = z_next >= 13'd2816 && (!pause || reset);
    wire cen_oki = o_next >= 12'd1408 && (!pause || reset);
    always @(posedge clk) begin
        // The board oscillators continue through reset. JTOPL2 needs enabled
        // reset clocks to initialize its register/operator pipelines.
        if(!pause || reset) begin
            z_acc <= z_next >= 2816 ? z_next-2816 : z_next;
            o_acc <= o_next >= 1408 ? o_next-1408 : o_next;
        end
    end
    wire [15:0] z80_addr;
    wire [7:0] z80_dout;
    reg [7:0] z80_din;
    wire z80_mreq_n,z80_iorq_n,z80_rd_n,z80_wr_n,z80_m1_n,z80_int_n;
    wire rom_lo_cs = !z80_mreq_n && z80_addr<16'h2000;
    wire rom_hi_cs = !z80_mreq_n && z80_addr[15];
    wire ram_cs = !z80_mreq_n && z80_addr>=16'h2000 && z80_addr<16'h2800;
    wire reg_cs = !z80_mreq_n && z80_addr[15:5]==11'h200;
    wire oki_cs = !z80_mreq_n && z80_addr==16'h6000;
    reg rom_bank;
    wire [15:0] rom_byte_addr = rom_hi_cs && rom_bank ? {1'b0,z80_addr[14:0]} : z80_addr;
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] rom_lo[0:32767],rom_hi[0:32767];
// Separate synchronous lane reads let Quartus infer the two M10K banks.
// Register the lane selector alongside them: the output still represents
// exactly the address sampled on the preceding clock, without extra latency.
reg [7:0] rom_lo_q,rom_hi_q;
reg rom_lane_q;
wire [7:0] z80_rom_q = rom_lane_q ? rom_hi_q : rom_lo_q;
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] zram[0:2047];
    reg [7:0] z80_ram_q;
    always @(posedge clk) begin
        if(ioctl_download && ioctl_wr && ioctl_addr>=ROM_BASE && ioctl_addr<ROM_BASE+27'h10000) begin
            rom_lo[ioctl_addr[15:1]] <= ioctl_dout[7:0];
            rom_hi[ioctl_addr[15:1]] <= ioctl_dout[15:8];
        end
 rom_lo_q <= rom_lo[rom_byte_addr[15:1]];
 rom_hi_q <= rom_hi[rom_byte_addr[15:1]];
 rom_lane_q <= rom_byte_addr[0];
        if(cen_z80 && ram_cs && !z80_wr_n) zram[z80_addr[10:0]]<=z80_dout;
        z80_ram_q<=zram[z80_addr[10:0]];
    end
	// ─── Sub-region decoder dentro reg_cs (z80_addr[4:0] = offset 0..31) ─────
	wire is_pending_w   = reg_cs && (z80_addr[4:0] == 5'h00) && !z80_wr_n;
	wire is_irq_clear   = reg_cs && (z80_addr[4:0] == 5'h01) && !z80_wr_n;
	wire is_rst10_ack   = reg_cs && (z80_addr[4:0] == 5'h02) && !z80_wr_n;
	wire is_rst18_ack   = reg_cs && (z80_addr[4:0] == 5'h03) && !z80_wr_n;
	wire is_bank_w      = reg_cs && (z80_addr[4:0] == 5'h1A) && !z80_wr_n;
	wire is_ym_access   = reg_cs && (z80_addr[4:1] == 4'h4);                      // 0x4008-0x4009
	wire is_ym_w        = is_ym_access && !z80_wr_n;
	wire is_ym_r        = is_ym_access && !z80_rd_n;
	wire is_latch_lo_r  = reg_cs && (z80_addr[4:0] == 5'h10) && !z80_rd_n;
	wire is_latch_hi_r  = reg_cs && (z80_addr[4:0] == 5'h11) && !z80_rd_n;
	wire is_pending_r   = reg_cs && (z80_addr[4:0] == 5'h12) && !z80_rd_n;
	wire is_coin_r      = reg_cs && (z80_addr[4:0] == 5'h13) && !z80_rd_n;
	wire is_data_lo_w   = reg_cs && (z80_addr[4:0] == 5'h18) && !z80_wr_n;
	wire is_data_hi_w   = reg_cs && (z80_addr[4:0] == 5'h19) && !z80_wr_n;
	wire is_coin_w      = reg_cs && (z80_addr[4:0] == 5'h1B) && !z80_wr_n;
	// ─── ROM bank register (Z80 0x4007: bit0 → bank 0/1) ─────────────────────
	// MAME seibu_sound_device::bank_w: m_rom_bank->set_entry(BIT(data,0))
	always @(posedge clk) begin
		if (reset)
			rom_bank <= 1'b0;
		else if (cen_z80 && is_bank_w)
			rom_bank <= z80_dout[0];
	end

	// ─── Soundlatch main↔sub state ───────────────────────────────────────────
	// 2-byte main2sub + 2-byte sub2main + flags pending
	reg [7:0] main2sub [0:1];
	reg [7:0] sub2main [0:1];
	reg       main2sub_pending;
	reg       sub2main_pending;

	// ─── IRQ controller (IM0 vector RST10/RST18) ─────────────────────────────
	// Stato: rst10_irq, rst10_service, rst18_irq, rst18_service
	// IRQ assertion logic:
	//   ASSERT: rst10_irq=1 (FM IRQ) o rst18_irq=1 (main wakeup)
	//   CLEAR: rst10_service=1 (durante service) o EOI restoraservice=0
	reg rst10_irq, rst10_service;
	reg rst18_irq, rst18_service;
	wire ym_irq_n;
	wire ym_irq = ~ym_irq_n;
	reg  ym_irq_d;

	// IM0 vector inject: durante m1+iorq (interrupt acknowledge) il device
	// fornisce 0xDF (RST18) o 0xD7 (RST10). RST18 ha priorità.
	// Il vector deve essere LATCHED all'inizio dell'IACK e tenuto stabile
	// per tutta la durata dell'IACK (può durare più cicli clk). Se calcolato
	// combinatoriale, quando rst18_irq viene cleared il vector torna a 00
	// e Z80 fetcha 00 invece del vector corretto. Bug verificato in sim.
	wire iack_active = ~z80_m1_n && ~z80_iorq_n;
	reg  iack_active_d;
	reg  [7:0] iack_vector_latched;
	wire [7:0] iack_vector_now =
	    (rst18_irq && !rst18_service) ? 8'hDF :
	    (rst10_irq && !rst10_service) ? 8'hD7 :
	                                    8'h00;
	// Latch al rising edge di iack_active
	always @(posedge clk) begin
		if (reset) begin
			iack_active_d       <= 1'b0;
			iack_vector_latched <= 8'h00;
		end
		else begin
			iack_active_d <= iack_active;
			if (iack_active && !iack_active_d) begin
				iack_vector_latched <= iack_vector_now;
			end
		end
	end
	wire [7:0] iack_vector = iack_active_d ? iack_vector_latched : iack_vector_now;

	// IRQ line al Z80: ASSERT se RST10 pending (e non in service) OR RST18 pending
	wire irq_active = (rst10_irq && !rst10_service) || (rst18_irq && !rst18_service);
	assign z80_int_n = ~irq_active;

	always @(posedge clk) begin
		if (reset) begin
			rst10_irq     <= 1'b0;
			rst10_service <= 1'b0;
			rst18_irq     <= 1'b0;
			rst18_service <= 1'b0;
			ym_irq_d      <= 1'b0;
		end
		else begin
			ym_irq_d <= ym_irq;
			// YM IRQ rising/falling → RST10 assert/clear
			if (ym_irq && !ym_irq_d)        rst10_irq <= 1'b1;
			else if (!ym_irq && ym_irq_d)   rst10_irq <= 1'b0;

			// Main writes to 0xA0008 (MAME offset 4) → assert RST18
			// snd_addr = bus_addr[3:1], 0xA0008 → bit[3:1]=100 = 4
			if (snd_cs && snd_wr && snd_addr == 3'd4)
				rst18_irq <= 1'b1;

			// Z80 acknowledges IRQ: FALLING edge di iack_active (= fine IACK)
			// Solo allora clear rst*_irq e set service. Durante IACK il vector
			// rimane latched (vedi sopra) e il Z80 lo fetcha correttamente.
			if (iack_active_d && !iack_active) begin
				if (iack_vector_latched == 8'hDF) begin
					rst18_service <= 1'b1;
					rst18_irq     <= 1'b0;
				end else if (iack_vector_latched == 8'hD7) begin
					rst10_service <= 1'b1;
				end
			end

			// Z80 EOI writes
			if (cen_z80) begin
				if (is_irq_clear)  rst18_service <= 1'b0;
				if (is_rst10_ack)  rst10_service <= 1'b0;
				if (is_rst18_ack)  rst18_service <= 1'b0;
			end
		end
	end

	// ─── Soundlatch main_w/r logic ──────────────────────────────────────────
	// snd_addr = bus_addr[3:1] = offset/2 (0=word 0, 1=word 1, 2=word 2, 3=word 3, 4=word 4, 5=word 5, 6=word 6)
	// MAME usa byte access (umask16 0x00ff = byte basso). Mappa offset MAME → snd_addr:
	//   offset 0 (0xA0000) → snd_addr 0
	//   offset 1 (0xA0002) → snd_addr 1
	//   offset 2 (0xA0004) → snd_addr 2
	//   offset 3 (0xA0006) → snd_addr 3
	//   offset 5 (0xA000A) → snd_addr 5
	//   offset 6 (0xA000C) → snd_addr 6
	always @(posedge clk) begin
		if (reset) begin
			main2sub[0]      <= 8'd0;
			main2sub[1]      <= 8'd0;
			sub2main[0]      <= 8'd0;
			sub2main[1]      <= 8'd0;
			main2sub_pending <= 1'b0;
			sub2main_pending <= 1'b0;
		end
		else begin
			// Main writes (MAME seibu_sound_device::main_w):
			//   case 0/1: m_main2sub[offset] = data
			//   case 4:   update_irq_lines(RST18_ASSERT) — gestito sopra
			//   case 2/6: pending flags (sub2main=0, main2sub=1)
			if (snd_cs && snd_wr) begin
				case (snd_addr)
					3'd0: main2sub[0] <= snd_wdata[7:0];
					3'd1: main2sub[1] <= snd_wdata[7:0];
					3'd2, 3'd6: begin                        // MAME case 2/6
						sub2main_pending <= 1'b0;
						main2sub_pending <= 1'b1;
					end
					default: ;
				endcase
			end
			// Z80 reads soundlatch (→ MAME implicit: nessun side effect)
			// Z80 writes sub2main
			if (cen_z80) begin
				if (is_data_lo_w) sub2main[0] <= z80_dout;
				if (is_data_hi_w) sub2main[1] <= z80_dout;
				if (is_pending_w) begin
					main2sub_pending <= 1'b0;
					sub2main_pending <= 1'b1;
				end
			end
		end
	end

	// snd_rdata: main legge 0xA0004 (offset 2), 0xA0006 (offset 3), 0xA000A (offset 5).
	// MAME seibu_sound_device::main_r (seibusound.cpp:285):
	//   offset 2,3: sub2main[0/1] (Z80 → main latch bytes)
	//   offset 5:   main2sub_pending (main chiede: Z80 ha letto il mio comando?)
	//   default:    0xFF
	// NO sdgndmps override per Raiden (era bug copiato da GundamSD)
	wire [7:0] main_r_data =
		(snd_addr == 3'd2) ? sub2main[0] :
		(snd_addr == 3'd3) ? sub2main[1] :
		(snd_addr == 3'd5) ? {7'd0, main2sub_pending} :
		                      8'hFF;
	assign snd_rdata = {8'h00, main_r_data};

    wire [7:0] ym_dout,oki_dout;
    wire signed [15:0] ym_snd;
    wire signed [13:0] oki_sound;
    wire ym_sample,oki_sample;
    jtopl2 u_fm (
        .rst(reset),.clk(clk),.cen(cen_z80),.din(z80_dout),.addr(z80_addr[0]),
        .cs_n(~is_ym_access),.wr_n(z80_wr_n),.dout(ym_dout),.irq_n(ym_irq_n),
        .fmvol0(8'h10),.fmvol1(8'h10),.fmvol2(8'h10),.fmvol3(8'h10),
        .fmvol4(8'h10),.fmvol5(8'h10),.fmvol6(8'h10),.fmvol7(8'h10),.fmvol8(8'h10),
        .snd(ym_snd),.sample(ym_sample)
    );
    jt6295 #(.INTERPOL(1),.SAMPLE(1)) u_adpcm (
        .rst(reset),.clk(clk),.cen(cen_oki),.ss(1'b1),
        .wrn(~(oki_cs && !z80_wr_n)),.din(z80_dout),.dout(oki_dout),
        .rom_addr(oki_rom_addr),.rom_data(oki_rom_data),.rom_ok(oki_rom_ok),
        .chvol0(8'h10),.chvol1(8'h10),.chvol2(8'h10),.chvol3(8'h10),
        .sound(oki_sound),.sample(oki_sample)
    );
	// ─── Z80 din mux ─────────────────────────────────────────────────────────
	always @(*) begin
		if (iack_active)         z80_din = iack_vector;
		else if (rom_lo_cs)      z80_din = z80_rom_q;
		else if (rom_hi_cs)      z80_din = z80_rom_q;       // Raiden ROM lineare
		else if (ram_cs)         z80_din = z80_ram_q;
		else if (is_ym_r)        z80_din = ym_dout;
		else if (is_latch_lo_r)  z80_din = main2sub[0];
		else if (is_latch_hi_r)  z80_din = main2sub[1];
		else if (is_pending_r)   z80_din = {7'd0, sub2main_pending};
		else if (is_coin_r)      z80_din = coin_input;
		else if (oki_cs)         z80_din = oki_dout;
		else                     z80_din = 8'hFF;
	end

    tv80s u_z80 (
        .reset_n(~reset),.clk(clk),.cen(cen_z80),.wait_n(1'b1),
        .int_n(z80_int_n),.nmi_n(1'b1),.busrq_n(1'b1),
        .m1_n(z80_m1_n),.mreq_n(z80_mreq_n),.iorq_n(z80_iorq_n),
        .rd_n(z80_rd_n),.wr_n(z80_wr_n),.rfsh_n(),.halt_n(),.busak_n(),
        .A(z80_addr),.di(z80_din),.dout(z80_dout)
    );
    // JT6295's 4x-interpolated output steps at ~31 kHz (every 3004/3379 clocks).
    // Sample-and-holding that staircase on the 49.7 kHz FM grid folded its
    // images to 15-20 kHz: audible grit on every ADPCM effect (modelled error
    // -18 dB). Linear interpolation between the last two OKI outputs over a
    // fixed 3004-clock span (one OKI step of latency) brings it to -31 dB.
    // oki_sample (cen_sr4) starts the 69-tap FIR, whose result lands 4*69+3 = 279
    // clocks later (jtframe_fir_mono steps every other clock); latch at 384.
    reg [8:0] oki_wait=0;
    reg [22:0] oki_pos=0;                          // span position, Q10 of 1/4096
    reg signed [13:0] oki_prev=0,oki_cur=0,oki_prev1=0,oki_prev2=0;
    reg signed [14:0] oki_diff=0;
    reg [12:0] oki_frac=0;
    reg signed [27:0] oki_step=0;
    reg signed [13:0] oki_lin=0;
    always @(posedge clk) begin
        if(reset) begin
            oki_wait<=0; oki_pos<=0; oki_prev<=0; oki_cur<=0;
        end else begin
            if(oki_sample) oki_wait<=9'd1;
            else if(oki_wait!=0) oki_wait<=oki_wait+9'd1;
            if(oki_wait==9'd384) begin
                oki_prev<=oki_cur; oki_cur<=oki_sound; oki_pos<=0;
            end else if(!oki_pos[22]) oki_pos<=oki_pos+23'd1396;  // 4096/3004 per clock
        end
        // Three aligned stages: prev travels with diff/frac so a latch never
        // combines a new base with the previous span's step.
        oki_diff <= oki_cur - oki_prev;  oki_prev1 <= oki_prev;
        oki_frac <= oki_pos[22] ? 13'd4096 : {1'b0,oki_pos[21:10]};
        oki_step <= oki_diff * $signed({1'b0,oki_frac});  oki_prev2 <= oki_prev1;
        oki_lin  <= oki_prev2 + $signed(oki_step[26:12]);
    end
    // MAME zeroteam routes: YM3812 -> mono 1.0, OKI6295 -> mono 0.40.
    // MAME scales the YM3812 as counts/32768 and each OKI voice as counts/2048,
    // so in 16-bit output counts the OKI weight is 0.40*16 = 6.4 of an ADPCM
    // unit (410/64). JT6295's 4x interpolator now has upstream unity gain; the
    // donor's x4 input made it 2x (phrase 14 rms 616.5 vs 309.3) and wrapped
    // its 14-bit output on loud effects. FM is unity. Measured against the MAME
    // capture, FM-only passages are level-matched; the previous 1/2 FM + 1x OKI
    // mix was 6 dB low overall and left the OKI ~10 dB under its MAME balance.
    // Six registered stages keep the 96 MHz paths short; every input is stable
    // for ~1900 clocks between samples, so the latch below simply waits for them.
    reg signed [22:0] oki_mul;
    reg signed [18:0] mix_sum;
    reg [18:0] lim_a;  reg lim_s1;
    reg signed [19:0] lim_d1,lim_d2;  reg [18:0] lim_a2;  reg lim_s2;
    reg [14:0] lim_y;  reg lim_s3;
    reg signed [15:0] mix_lim;
    always @(posedge clk) begin
        oki_mul <= oki_lin * 10'sd410;
        mix_sum <= $signed(ym_snd) + (oki_mul >>> 6);
        // Soft limiter: unity to 3/4 full scale, then slopes 1/2 and 1/8 that
        // reach full scale at |mix| = 53248, so a loud blast rounds off
        // instead of hard-clipping into harsh square-wave harmonics.
        lim_a  <= mix_sum[18] ? -mix_sum : mix_sum;  lim_s1 <= mix_sum[18];
        lim_d1 <= $signed({1'b0,lim_a}) - 20'sd24576;
        lim_d2 <= $signed({1'b0,lim_a}) - 20'sd36864;
        lim_a2 <= lim_a;  lim_s2 <= lim_s1;
        lim_y  <= lim_d1[19] ? lim_a2[14:0] :
                  lim_d2[19] ? 15'd24576 + {1'b0,lim_d1[14:1]} :
                  lim_d2 < 20'sd16384 ? 15'd30720 + {3'b0,lim_d2[14:3]} : 15'd32767;
        lim_s3 <= lim_s2;
        mix_lim <= lim_s3 ? -$signed({1'b0,lim_y}) : $signed({1'b0,lim_y});
    end
    reg [8:0] sample_dly;
    reg sample_pulse;
    wire sample_latch = sample_dly[7] && !sample_dly[8];
    always @(posedge clk) begin
        sample_dly<={sample_dly[7:0],ym_sample};
        sample_pulse<=sample_latch && !pause;
        if(reset) begin audio_l<=0; audio_r<=0;sample_dly<=0;sample_pulse<=0;end
        else if(sample_latch && !pause) begin
            audio_l<=mix_lim;
            audio_r<=mix_lim;
        end
    end
    ZeroTeam_resample48 u_out48 (
        .clk(clk),.reset(reset),.in_sample(sample_pulse),.in_data(audio_l),
        .out_data(out_l),.out_sample(out_sample)
    );
    assign out_r = out_l;
    assign audio_sample=sample_pulse;
    assign debug_address=z80_addr;
    assign debug_data=z80_dout;
    assign debug_din=z80_din;
    assign debug_read=!z80_mreq_n && !z80_rd_n;
    assign debug_write=!z80_mreq_n && !z80_wr_n;
    assign debug_fetch=!z80_m1_n && !z80_mreq_n;
    assign debug_iack=iack_active;
    assign debug_cen=cen_z80;
    assign debug_ym_irq=ym_irq;
    assign debug_pending=main2sub_pending;
endmodule

// Fractional-delay resampler: 49.716 kHz FM-rate samples -> exactly 48 kHz.
// The MiSTer audio block samples AUDIO_L once per 48 kHz tick, so feeding it a
// 49.716 kHz sample-and-hold stream makes it drop a repeated/skipped sample
// about 1.7 thousand times a second; measured on the replayed game audio that
// jitter noise is as loud as the 4-20 kHz music content itself. Here each
// 48 kHz output is an 8-tap Lanczos-4 interpolation (64 phases, Q1.14) of the
// last eight input samples at the instant between ages 4 and 3, i.e. about
// four input samples (80 us) of latency. clk must be 96 MHz (2000 per tick).
module ZeroTeam_resample48 (
    input wire clk,reset,
    input wire in_sample,
    input wire signed [15:0] in_data,
    output reg signed [15:0] out_data,
    output reg out_sample
);
    (* romstyle="M10K" *) reg signed [15:0] rom[0:511];
    initial begin
// TABLE BEGIN (scripts/gen_resample_table.py)
        rom[9'd0] = 16'sd0;
        rom[9'd1] = 16'sd13;
        rom[9'd2] = -16'sd41;
        rom[9'd3] = 16'sd116;
        rom[9'd4] = 16'sd16383;
        rom[9'd5] = -16'sd114;
        rom[9'd6] = 16'sd40;
        rom[9'd7] = -16'sd13;
        rom[9'd8] = -16'sd1;
        rom[9'd9] = 16'sd40;
        rom[9'd10] = -16'sd125;
        rom[9'd11] = 16'sd355;
        rom[9'd12] = 16'sd16369;
        rom[9'd13] = -16'sd336;
        rom[9'd14] = 16'sd119;
        rom[9'd15] = -16'sd37;
        rom[9'd16] = -16'sd2;
        rom[9'd17] = 16'sd68;
        rom[9'd18] = -16'sd211;
        rom[9'd19] = 16'sd603;
        rom[9'd20] = 16'sd16339;
        rom[9'd21] = -16'sd548;
        rom[9'd22] = 16'sd195;
        rom[9'd23] = -16'sd60;
        rom[9'd24] = -16'sd3;
        rom[9'd25] = 16'sd96;
        rom[9'd26] = -16'sd300;
        rom[9'd27] = 16'sd859;
        rom[9'd28] = 16'sd16297;
        rom[9'd29] = -16'sd752;
        rom[9'd30] = 16'sd269;
        rom[9'd31] = -16'sd82;
        rom[9'd32] = -16'sd5;
        rom[9'd33] = 16'sd126;
        rom[9'd34] = -16'sd390;
        rom[9'd35] = 16'sd1123;
        rom[9'd36] = 16'sd16240;
        rom[9'd37] = -16'sd946;
        rom[9'd38] = 16'sd339;
        rom[9'd39] = -16'sd103;
        rom[9'd40] = -16'sd8;
        rom[9'd41] = 16'sd157;
        rom[9'd42] = -16'sd482;
        rom[9'd43] = 16'sd1394;
        rom[9'd44] = 16'sd16170;
        rom[9'd45] = -16'sd1131;
        rom[9'd46] = 16'sd406;
        rom[9'd47] = -16'sd122;
        rom[9'd48] = -16'sd11;
        rom[9'd49] = 16'sd189;
        rom[9'd50] = -16'sd576;
        rom[9'd51] = 16'sd1673;
        rom[9'd52] = 16'sd16085;
        rom[9'd53] = -16'sd1306;
        rom[9'd54] = 16'sd470;
        rom[9'd55] = -16'sd140;
        rom[9'd56] = -16'sd15;
        rom[9'd57] = 16'sd221;
        rom[9'd58] = -16'sd671;
        rom[9'd59] = 16'sd1959;
        rom[9'd60] = 16'sd15988;
        rom[9'd61] = -16'sd1472;
        rom[9'd62] = 16'sd531;
        rom[9'd63] = -16'sd157;
        rom[9'd64] = -16'sd19;
        rom[9'd65] = 16'sd254;
        rom[9'd66] = -16'sd767;
        rom[9'd67] = 16'sd2252;
        rom[9'd68] = 16'sd15877;
        rom[9'd69] = -16'sd1628;
        rom[9'd70] = 16'sd588;
        rom[9'd71] = -16'sd173;
        rom[9'd72] = -16'sd23;
        rom[9'd73] = 16'sd288;
        rom[9'd74] = -16'sd864;
        rom[9'd75] = 16'sd2551;
        rom[9'd76] = 16'sd15752;
        rom[9'd77] = -16'sd1775;
        rom[9'd78] = 16'sd642;
        rom[9'd79] = -16'sd187;
        rom[9'd80] = -16'sd29;
        rom[9'd81] = 16'sd322;
        rom[9'd82] = -16'sd962;
        rom[9'd83] = 16'sd2857;
        rom[9'd84] = 16'sd15614;
        rom[9'd85] = -16'sd1912;
        rom[9'd86] = 16'sd693;
        rom[9'd87] = -16'sd199;
        rom[9'd88] = -16'sd34;
        rom[9'd89] = 16'sd357;
        rom[9'd90] = -16'sd1061;
        rom[9'd91] = 16'sd3168;
        rom[9'd92] = 16'sd15464;
        rom[9'd93] = -16'sd2039;
        rom[9'd94] = 16'sd740;
        rom[9'd95] = -16'sd211;
        rom[9'd96] = -16'sd40;
        rom[9'd97] = 16'sd392;
        rom[9'd98] = -16'sd1159;
        rom[9'd99] = 16'sd3485;
        rom[9'd100] = 16'sd15301;
        rom[9'd101] = -16'sd2157;
        rom[9'd102] = 16'sd783;
        rom[9'd103] = -16'sd221;
        rom[9'd104] = -16'sd47;
        rom[9'd105] = 16'sd427;
        rom[9'd106] = -16'sd1258;
        rom[9'd107] = 16'sd3807;
        rom[9'd108] = 16'sd15128;
        rom[9'd109] = -16'sd2266;
        rom[9'd110] = 16'sd823;
        rom[9'd111] = -16'sd230;
        rom[9'd112] = -16'sd54;
        rom[9'd113] = 16'sd462;
        rom[9'd114] = -16'sd1356;
        rom[9'd115] = 16'sd4134;
        rom[9'd116] = 16'sd14941;
        rom[9'd117] = -16'sd2365;
        rom[9'd118] = 16'sd860;
        rom[9'd119] = -16'sd238;
        rom[9'd120] = -16'sd61;
        rom[9'd121] = 16'sd498;
        rom[9'd122] = -16'sd1453;
        rom[9'd123] = 16'sd4465;
        rom[9'd124] = 16'sd14740;
        rom[9'd125] = -16'sd2454;
        rom[9'd126] = 16'sd893;
        rom[9'd127] = -16'sd244;
        rom[9'd128] = -16'sd69;
        rom[9'd129] = 16'sd533;
        rom[9'd130] = -16'sd1550;
        rom[9'd131] = 16'sd4799;
        rom[9'd132] = 16'sd14531;
        rom[9'd133] = -16'sd2534;
        rom[9'd134] = 16'sd923;
        rom[9'd135] = -16'sd249;
        rom[9'd136] = -16'sd77;
        rom[9'd137] = 16'sd568;
        rom[9'd138] = -16'sd1646;
        rom[9'd139] = 16'sd5137;
        rom[9'd140] = 16'sd14311;
        rom[9'd141] = -16'sd2605;
        rom[9'd142] = 16'sd949;
        rom[9'd143] = -16'sd253;
        rom[9'd144] = -16'sd85;
        rom[9'd145] = 16'sd603;
        rom[9'd146] = -16'sd1740;
        rom[9'd147] = 16'sd5479;
        rom[9'd148] = 16'sd14079;
        rom[9'd149] = -16'sd2668;
        rom[9'd150] = 16'sd972;
        rom[9'd151] = -16'sd256;
        rom[9'd152] = -16'sd94;
        rom[9'd153] = 16'sd638;
        rom[9'd154] = -16'sd1832;
        rom[9'd155] = 16'sd5822;
        rom[9'd156] = 16'sd13838;
        rom[9'd157] = -16'sd2721;
        rom[9'd158] = 16'sd991;
        rom[9'd159] = -16'sd258;
        rom[9'd160] = -16'sd103;
        rom[9'd161] = 16'sd671;
        rom[9'd162] = -16'sd1922;
        rom[9'd163] = 16'sd6168;
        rom[9'd164] = 16'sd13586;
        rom[9'd165] = -16'sd2765;
        rom[9'd166] = 16'sd1007;
        rom[9'd167] = -16'sd258;
        rom[9'd168] = -16'sd112;
        rom[9'd169] = 16'sd704;
        rom[9'd170] = -16'sd2010;
        rom[9'd171] = 16'sd6515;
        rom[9'd172] = 16'sd13327;
        rom[9'd173] = -16'sd2802;
        rom[9'd174] = 16'sd1020;
        rom[9'd175] = -16'sd258;
        rom[9'd176] = -16'sd121;
        rom[9'd177] = 16'sd737;
        rom[9'd178] = -16'sd2096;
        rom[9'd179] = 16'sd6864;
        rom[9'd180] = 16'sd13056;
        rom[9'd181] = -16'sd2829;
        rom[9'd182] = 16'sd1030;
        rom[9'd183] = -16'sd257;
        rom[9'd184] = -16'sd131;
        rom[9'd185] = 16'sd768;
        rom[9'd186] = -16'sd2178;
        rom[9'd187] = 16'sd7213;
        rom[9'd188] = 16'sd12780;
        rom[9'd189] = -16'sd2849;
        rom[9'd190] = 16'sd1036;
        rom[9'd191] = -16'sd255;
        rom[9'd192] = -16'sd140;
        rom[9'd193] = 16'sd799;
        rom[9'd194] = -16'sd2258;
        rom[9'd195] = 16'sd7562;
        rom[9'd196] = 16'sd12494;
        rom[9'd197] = -16'sd2861;
        rom[9'd198] = 16'sd1040;
        rom[9'd199] = -16'sd252;
        rom[9'd200] = -16'sd149;
        rom[9'd201] = 16'sd828;
        rom[9'd202] = -16'sd2334;
        rom[9'd203] = 16'sd7911;
        rom[9'd204] = 16'sd12200;
        rom[9'd205] = -16'sd2865;
        rom[9'd206] = 16'sd1041;
        rom[9'd207] = -16'sd248;
        rom[9'd208] = -16'sd159;
        rom[9'd209] = 16'sd856;
        rom[9'd210] = -16'sd2406;
        rom[9'd211] = 16'sd8260;
        rom[9'd212] = 16'sd11899;
        rom[9'd213] = -16'sd2861;
        rom[9'd214] = 16'sd1038;
        rom[9'd215] = -16'sd243;
        rom[9'd216] = -16'sd168;
        rom[9'd217] = 16'sd882;
        rom[9'd218] = -16'sd2473;
        rom[9'd219] = 16'sd8607;
        rom[9'd220] = 16'sd11591;
        rom[9'd221] = -16'sd2850;
        rom[9'd222] = 16'sd1033;
        rom[9'd223] = -16'sd238;
        rom[9'd224] = -16'sd177;
        rom[9'd225] = 16'sd907;
        rom[9'd226] = -16'sd2537;
        rom[9'd227] = 16'sd8952;
        rom[9'd228] = 16'sd11279;
        rom[9'd229] = -16'sd2833;
        rom[9'd230] = 16'sd1025;
        rom[9'd231] = -16'sd232;
        rom[9'd232] = -16'sd186;
        rom[9'd233] = 16'sd930;
        rom[9'd234] = -16'sd2596;
        rom[9'd235] = 16'sd9295;
        rom[9'd236] = 16'sd10960;
        rom[9'd237] = -16'sd2808;
        rom[9'd238] = 16'sd1015;
        rom[9'd239] = -16'sd226;
        rom[9'd240] = -16'sd195;
        rom[9'd241] = 16'sd951;
        rom[9'd242] = -16'sd2649;
        rom[9'd243] = 16'sd9635;
        rom[9'd244] = 16'sd10635;
        rom[9'd245] = -16'sd2778;
        rom[9'd246] = 16'sd1003;
        rom[9'd247] = -16'sd218;
        rom[9'd248] = -16'sd203;
        rom[9'd249] = 16'sd970;
        rom[9'd250] = -16'sd2698;
        rom[9'd251] = 16'sd9973;
        rom[9'd252] = 16'sd10306;
        rom[9'd253] = -16'sd2741;
        rom[9'd254] = 16'sd988;
        rom[9'd255] = -16'sd211;
        rom[9'd256] = -16'sd211;
        rom[9'd257] = 16'sd988;
        rom[9'd258] = -16'sd2741;
        rom[9'd259] = 16'sd10306;
        rom[9'd260] = 16'sd9973;
        rom[9'd261] = -16'sd2698;
        rom[9'd262] = 16'sd970;
        rom[9'd263] = -16'sd203;
        rom[9'd264] = -16'sd218;
        rom[9'd265] = 16'sd1003;
        rom[9'd266] = -16'sd2778;
        rom[9'd267] = 16'sd10635;
        rom[9'd268] = 16'sd9635;
        rom[9'd269] = -16'sd2649;
        rom[9'd270] = 16'sd951;
        rom[9'd271] = -16'sd195;
        rom[9'd272] = -16'sd226;
        rom[9'd273] = 16'sd1015;
        rom[9'd274] = -16'sd2808;
        rom[9'd275] = 16'sd10960;
        rom[9'd276] = 16'sd9295;
        rom[9'd277] = -16'sd2596;
        rom[9'd278] = 16'sd930;
        rom[9'd279] = -16'sd186;
        rom[9'd280] = -16'sd232;
        rom[9'd281] = 16'sd1025;
        rom[9'd282] = -16'sd2833;
        rom[9'd283] = 16'sd11279;
        rom[9'd284] = 16'sd8952;
        rom[9'd285] = -16'sd2537;
        rom[9'd286] = 16'sd907;
        rom[9'd287] = -16'sd177;
        rom[9'd288] = -16'sd238;
        rom[9'd289] = 16'sd1033;
        rom[9'd290] = -16'sd2850;
        rom[9'd291] = 16'sd11591;
        rom[9'd292] = 16'sd8607;
        rom[9'd293] = -16'sd2473;
        rom[9'd294] = 16'sd882;
        rom[9'd295] = -16'sd168;
        rom[9'd296] = -16'sd243;
        rom[9'd297] = 16'sd1038;
        rom[9'd298] = -16'sd2861;
        rom[9'd299] = 16'sd11899;
        rom[9'd300] = 16'sd8260;
        rom[9'd301] = -16'sd2406;
        rom[9'd302] = 16'sd856;
        rom[9'd303] = -16'sd159;
        rom[9'd304] = -16'sd248;
        rom[9'd305] = 16'sd1041;
        rom[9'd306] = -16'sd2865;
        rom[9'd307] = 16'sd12200;
        rom[9'd308] = 16'sd7911;
        rom[9'd309] = -16'sd2334;
        rom[9'd310] = 16'sd828;
        rom[9'd311] = -16'sd149;
        rom[9'd312] = -16'sd252;
        rom[9'd313] = 16'sd1040;
        rom[9'd314] = -16'sd2861;
        rom[9'd315] = 16'sd12494;
        rom[9'd316] = 16'sd7562;
        rom[9'd317] = -16'sd2258;
        rom[9'd318] = 16'sd799;
        rom[9'd319] = -16'sd140;
        rom[9'd320] = -16'sd255;
        rom[9'd321] = 16'sd1036;
        rom[9'd322] = -16'sd2849;
        rom[9'd323] = 16'sd12780;
        rom[9'd324] = 16'sd7213;
        rom[9'd325] = -16'sd2178;
        rom[9'd326] = 16'sd768;
        rom[9'd327] = -16'sd131;
        rom[9'd328] = -16'sd257;
        rom[9'd329] = 16'sd1030;
        rom[9'd330] = -16'sd2829;
        rom[9'd331] = 16'sd13056;
        rom[9'd332] = 16'sd6864;
        rom[9'd333] = -16'sd2096;
        rom[9'd334] = 16'sd737;
        rom[9'd335] = -16'sd121;
        rom[9'd336] = -16'sd258;
        rom[9'd337] = 16'sd1020;
        rom[9'd338] = -16'sd2802;
        rom[9'd339] = 16'sd13327;
        rom[9'd340] = 16'sd6515;
        rom[9'd341] = -16'sd2010;
        rom[9'd342] = 16'sd704;
        rom[9'd343] = -16'sd112;
        rom[9'd344] = -16'sd258;
        rom[9'd345] = 16'sd1007;
        rom[9'd346] = -16'sd2765;
        rom[9'd347] = 16'sd13586;
        rom[9'd348] = 16'sd6168;
        rom[9'd349] = -16'sd1922;
        rom[9'd350] = 16'sd671;
        rom[9'd351] = -16'sd103;
        rom[9'd352] = -16'sd258;
        rom[9'd353] = 16'sd991;
        rom[9'd354] = -16'sd2721;
        rom[9'd355] = 16'sd13838;
        rom[9'd356] = 16'sd5822;
        rom[9'd357] = -16'sd1832;
        rom[9'd358] = 16'sd638;
        rom[9'd359] = -16'sd94;
        rom[9'd360] = -16'sd256;
        rom[9'd361] = 16'sd972;
        rom[9'd362] = -16'sd2668;
        rom[9'd363] = 16'sd14079;
        rom[9'd364] = 16'sd5479;
        rom[9'd365] = -16'sd1740;
        rom[9'd366] = 16'sd603;
        rom[9'd367] = -16'sd85;
        rom[9'd368] = -16'sd253;
        rom[9'd369] = 16'sd949;
        rom[9'd370] = -16'sd2605;
        rom[9'd371] = 16'sd14311;
        rom[9'd372] = 16'sd5137;
        rom[9'd373] = -16'sd1646;
        rom[9'd374] = 16'sd568;
        rom[9'd375] = -16'sd77;
        rom[9'd376] = -16'sd249;
        rom[9'd377] = 16'sd923;
        rom[9'd378] = -16'sd2534;
        rom[9'd379] = 16'sd14531;
        rom[9'd380] = 16'sd4799;
        rom[9'd381] = -16'sd1550;
        rom[9'd382] = 16'sd533;
        rom[9'd383] = -16'sd69;
        rom[9'd384] = -16'sd244;
        rom[9'd385] = 16'sd893;
        rom[9'd386] = -16'sd2454;
        rom[9'd387] = 16'sd14740;
        rom[9'd388] = 16'sd4465;
        rom[9'd389] = -16'sd1453;
        rom[9'd390] = 16'sd498;
        rom[9'd391] = -16'sd61;
        rom[9'd392] = -16'sd238;
        rom[9'd393] = 16'sd860;
        rom[9'd394] = -16'sd2365;
        rom[9'd395] = 16'sd14941;
        rom[9'd396] = 16'sd4134;
        rom[9'd397] = -16'sd1356;
        rom[9'd398] = 16'sd462;
        rom[9'd399] = -16'sd54;
        rom[9'd400] = -16'sd230;
        rom[9'd401] = 16'sd823;
        rom[9'd402] = -16'sd2266;
        rom[9'd403] = 16'sd15128;
        rom[9'd404] = 16'sd3807;
        rom[9'd405] = -16'sd1258;
        rom[9'd406] = 16'sd427;
        rom[9'd407] = -16'sd47;
        rom[9'd408] = -16'sd221;
        rom[9'd409] = 16'sd783;
        rom[9'd410] = -16'sd2157;
        rom[9'd411] = 16'sd15301;
        rom[9'd412] = 16'sd3485;
        rom[9'd413] = -16'sd1159;
        rom[9'd414] = 16'sd392;
        rom[9'd415] = -16'sd40;
        rom[9'd416] = -16'sd211;
        rom[9'd417] = 16'sd740;
        rom[9'd418] = -16'sd2039;
        rom[9'd419] = 16'sd15464;
        rom[9'd420] = 16'sd3168;
        rom[9'd421] = -16'sd1061;
        rom[9'd422] = 16'sd357;
        rom[9'd423] = -16'sd34;
        rom[9'd424] = -16'sd199;
        rom[9'd425] = 16'sd693;
        rom[9'd426] = -16'sd1912;
        rom[9'd427] = 16'sd15614;
        rom[9'd428] = 16'sd2857;
        rom[9'd429] = -16'sd962;
        rom[9'd430] = 16'sd322;
        rom[9'd431] = -16'sd29;
        rom[9'd432] = -16'sd187;
        rom[9'd433] = 16'sd642;
        rom[9'd434] = -16'sd1775;
        rom[9'd435] = 16'sd15752;
        rom[9'd436] = 16'sd2551;
        rom[9'd437] = -16'sd864;
        rom[9'd438] = 16'sd288;
        rom[9'd439] = -16'sd23;
        rom[9'd440] = -16'sd173;
        rom[9'd441] = 16'sd588;
        rom[9'd442] = -16'sd1628;
        rom[9'd443] = 16'sd15877;
        rom[9'd444] = 16'sd2252;
        rom[9'd445] = -16'sd767;
        rom[9'd446] = 16'sd254;
        rom[9'd447] = -16'sd19;
        rom[9'd448] = -16'sd157;
        rom[9'd449] = 16'sd531;
        rom[9'd450] = -16'sd1472;
        rom[9'd451] = 16'sd15988;
        rom[9'd452] = 16'sd1959;
        rom[9'd453] = -16'sd671;
        rom[9'd454] = 16'sd221;
        rom[9'd455] = -16'sd15;
        rom[9'd456] = -16'sd140;
        rom[9'd457] = 16'sd470;
        rom[9'd458] = -16'sd1306;
        rom[9'd459] = 16'sd16085;
        rom[9'd460] = 16'sd1673;
        rom[9'd461] = -16'sd576;
        rom[9'd462] = 16'sd189;
        rom[9'd463] = -16'sd11;
        rom[9'd464] = -16'sd122;
        rom[9'd465] = 16'sd406;
        rom[9'd466] = -16'sd1131;
        rom[9'd467] = 16'sd16170;
        rom[9'd468] = 16'sd1394;
        rom[9'd469] = -16'sd482;
        rom[9'd470] = 16'sd157;
        rom[9'd471] = -16'sd8;
        rom[9'd472] = -16'sd103;
        rom[9'd473] = 16'sd339;
        rom[9'd474] = -16'sd946;
        rom[9'd475] = 16'sd16240;
        rom[9'd476] = 16'sd1123;
        rom[9'd477] = -16'sd390;
        rom[9'd478] = 16'sd126;
        rom[9'd479] = -16'sd5;
        rom[9'd480] = -16'sd82;
        rom[9'd481] = 16'sd269;
        rom[9'd482] = -16'sd752;
        rom[9'd483] = 16'sd16297;
        rom[9'd484] = 16'sd859;
        rom[9'd485] = -16'sd300;
        rom[9'd486] = 16'sd96;
        rom[9'd487] = -16'sd3;
        rom[9'd488] = -16'sd60;
        rom[9'd489] = 16'sd195;
        rom[9'd490] = -16'sd548;
        rom[9'd491] = 16'sd16339;
        rom[9'd492] = 16'sd603;
        rom[9'd493] = -16'sd211;
        rom[9'd494] = 16'sd68;
        rom[9'd495] = -16'sd2;
        rom[9'd496] = -16'sd37;
        rom[9'd497] = 16'sd119;
        rom[9'd498] = -16'sd336;
        rom[9'd499] = 16'sd16369;
        rom[9'd500] = 16'sd355;
        rom[9'd501] = -16'sd125;
        rom[9'd502] = 16'sd40;
        rom[9'd503] = -16'sd1;
        rom[9'd504] = -16'sd13;
        rom[9'd505] = 16'sd40;
        rom[9'd506] = -16'sd114;
        rom[9'd507] = 16'sd16383;
        rom[9'd508] = 16'sd116;
        rom[9'd509] = -16'sd41;
        rom[9'd510] = 16'sd13;
        rom[9'd511] = 16'sd0;
// TABLE END
    end
    reg signed [15:0] h0,h1,h2,h3,h4,h5,h6,h7;     // h0 newest
    reg signed [15:0] s0,s1,s2,s3,s4,s5,s6,s7;     // snapshot for one output
    reg [10:0] age=0;                              // clocks since newest sample
    reg [11:0] cnt=0;
    reg [5:0] phase_q,ph;
    wire [22:0] phase_m = age * 12'd2172;          // 64 / 1930.7 clocks
    reg pending=0,run=0;
    reg [3:0] st=0;
    reg signed [15:0] coef_q,samp_q;
    reg signed [31:0] prod;
    reg signed [34:0] acc;
    reg signed [15:0] sel;
    always @(*) case(st[2:0])
        3'd0: sel=s0; 3'd1: sel=s1; 3'd2: sel=s2; 3'd3: sel=s3;
        3'd4: sel=s4; 3'd5: sel=s5; 3'd6: sel=s6; default: sel=s7;
    endcase
    wire signed [34:0] acc_r = acc + 35'sd8192;    // round to nearest
    wire signed [20:0] res = acc_r[34:14];
    always @(posedge clk) begin
        out_sample <= 0;
        phase_q <= phase_m[22:16] > 7'd63 ? 6'd63 : phase_m[21:16];
        if(reset) begin
            {h0,h1,h2,h3,h4,h5,h6,h7} <= 0; age<=0; cnt<=0; pending<=0; run<=0;
            out_data<=0;
        end else begin
            cnt <= cnt==12'd1999 ? 12'd0 : cnt+12'd1;
            if(cnt==12'd1999) pending <= 1;
            if(in_sample) begin
                {h7,h6,h5,h4,h3,h2,h1} <= {h6,h5,h4,h3,h2,h1,h0};
                h0 <= in_data; age <= 0;
            end else if(age!=11'd2047) age <= age+11'd1;
            // Wait until phase_q reflects the newest sample before snapshotting.
            if(pending && age>=11'd4 && !run) begin
                pending<=0; run<=1; st<=0; ph<=phase_q;
                {s0,s1,s2,s3,s4,s5,s6,s7} <= {h0,h1,h2,h3,h4,h5,h6,h7};
            end else if(run) begin
                st <= st+4'd1;
                if(st<8) begin coef_q<=rom[{ph,st[2:0]}]; samp_q<=sel; end
                prod <= samp_q*coef_q;
                if(st>=4'd2 && st<=4'd9) acc <= (st==4'd2 ? 35'sd0 : acc) + prod;
                if(st==4'd10) begin
                    out_data <= res>21'sd32767 ? 16'sh7fff : res< -21'sd32768 ? 16'sh8000 : res[15:0];
                    out_sample <= 1; run <= 0;
                end
            end
        end
    end
endmodule
