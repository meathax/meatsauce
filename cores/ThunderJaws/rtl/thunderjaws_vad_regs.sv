// SPDX-License-Identifier: GPL-3.0-or-later
// ThunderJaws VAD register/parameter interface, adapted from Batman MiSTer
// batman_vad_regs.sv, commit34783858f6e1511e299ef159d6316544934f8fb5.
// Original copyright(C)2026 Batman MiSTer core authors; see donors/video/NOTICE.md.
// Target baseline: MAME0.289 atarivad.cpp. CPU writes are one-cycle commit
// strobes with byte enables. EOF starts at the supplied native frame-zero event,
// is not gated by Batman-specific enable assumptions, and retains acknowledged
// data until it can commit. Linescroll producer holds valid/data until ready.
`timescale 1ns/1ps

module thunderjaws_vad_regs #(
	parameter int  EOF_LAST       = 'h1B,   // last EOF index replayed (as MAME)
	parameter bit  EOF_SKIP_ZERO  = 1'b1,   // skip zero words (as MAME)
	// Regs01-1F return their stored value, matching current MAME control_read.
	parameter bit  READBACK_SHADOW= 1'b1,
	parameter bit  HONOUR_ENABLE14= 1'b0,   // reg 00 bit 14 suspends the DMA
	// PF2 shares PF1's fine scroll phase (see playfield_xscroll below).  Should stay 1.
	parameter bit  COUPLE_FINE    = 1'b1
)(
	input  logic        clk,
	input  logic        reset, // game/device reset: drain outstanding EOF
    input logic init_reset, // coherent backend cancellation/reset

	// ---- the 68000 port (0x3EFFC0-0x3EFFFF) ----------
	input  logic        cpu_cs,
	input  logic        cpu_we,
	input  logic  [4:0] cpu_a,          // the register index
	input  logic [15:0] cpu_din,
    input logic [1:0] cpu_lanes, // bit1 high byte, bit0 low byte
	output logic [15:0] cpu_dout,

	// ---- the raster, for the reg-00 readback and the DMA trigger ---------
	input  logic  [8:0] vpos,
	input  logic        eof_start,   // one pulse at native frame zero (MAME baseline)

	// ---- the EOF parameter RAM read port (video RAM 0x3F8F00-0x3F8F7F) ---
	output logic        eof_req,
	output logic  [5:0] eof_idx,
	input  logic [15:0] eof_data,
	input  logic        eof_ack,

	// ---- the linescroll feed into the decoder (batman_vad_dma) ------------
	// Reaches the decoder only, never the register file (it has no index).
	// Producer holds valid/data until ls_ready; flush unaccepted words on reset.
	input  logic        ls_wr, // held valid
    output wire ls_ready,
	input  logic [15:0] ls_d,

	// ---- the register file, fanned out -----------------------------------
	output logic [15:0] reg_enable,     // 00
	output logic [15:0] reg_vsy,        // 01
	output logic [15:0] reg_vbl,        // 02
	output logic [15:0] reg_vint,       // 03
	output logic [15:0] reg_hsy,        // 04
	output logic [15:0] reg_hbl,        // 05
	output logic [15:0] reg_slip,       // 06
	output logic [15:0] reg_apdma,      // 07
	output logic [15:0] reg_pmbase,     // 08
	output logic [15:0] reg_albase,     // 09
	output logic [15:0] reg_opt,        // 0A
	output logic [15:0] reg_mocon,      // 10  -> the MOB
	output logic [15:0] reg_pcon,       // 11  -> the MOB
	output logic [15:0] reg_grcon,      // 12  -> the MOB
	output logic        mob_wr,         // one pulse per 10/11/12 write (/MOBWR)
	output logic  [1:0] mob_sel,        // which of the three

	// ---- the decoded scrolls ---------------------------------------------
	output logic  [8:0] mo_xscroll,     // tag 9
	output logic  [8:0] playfield2_xscroll,    // tag A  (MAME m_playfield2_xscroll_raw)
	output logic  [8:0] playfield_xscroll,    // tag B  (MAME m_pf0_xscroll_raw),
	                                    //        plus PF1's fine phase
	output logic  [8:0] playfield_xscroll_raw,
	output logic  [8:0] mo_yscroll,     // tag D
	output logic  [8:0] playfield2_yscroll,    // tag E
	output logic  [8:0] playfield_yscroll,    // tag F

	// ---- the attribute autostore ------------------------------------------
	output logic  [7:0] attr_msb_latch, // reg 1C, high byte source
	output logic  [7:0] attr_lsb_latch, // reg 1D, low byte source
	output logic        oas_en,         // reg 0A bit 7, toggled by the game

	// ---- the rest of reg 0A (after the comma: the value Batman uses) -------
	output logic        ols_en,         // bit 13  linescroll, 0
	output logic        oslpink,        // bit 12  split links, 0
	output logic        osloram,        // bit 11  slow MO DMA cycles, 0
	output logic        o_dcdma,        // bit 10  double-time colour-RAM DMA, 1
	output logic        o_dvdma,        // bit  9  double-time video-RAM DMA, 0
	output logic        oadroen,        // bit  8  address bus tri-state, 0
	output logic        ocrdwe,         // bit  6  8-bit colour RAM, 0
	output logic        ovrdtack,       // bit  5  video-RAM writes wait, 0
	output logic        ocrdtack,       // bit  4  colour-RAM writes wait, 1
	output logic        opium,          // bit 14  playfield 2 enabled, 1
	output logic        opfhsiz_pf2at,  // bit 15  PF2 attribute -1, 0

	// ---- the master enables ----------------------------------------------
	output logic        vad_enable,     // reg 00 bit 15
	output logic        dma_enable,     // reg 00 bit 15 & !bit 14

	// ---- the scanline interrupt ------------------------------------------
	output logic        irq_arm,        // any write to reg 03
	output logic        irq_ack,        // any committed write to reg 1E
    output wire [8:0] irq_target,       // merged target value WITH irq_arm
    output logic palette_bank,         // reset0; updates only on reg0A writes
    output wire [15:0] irq_word         // full merged word WITH irq_arm
);

	// =====================================================================
	// The shadow file
	// =====================================================================
	logic [15:0] regs [0:31];

	assign reg_enable = regs[5'h00];
	assign reg_vsy    = regs[5'h01];
	assign reg_vbl    = regs[5'h02];
	assign reg_vint   = regs[5'h03];
	assign reg_hsy    = regs[5'h04];
	assign reg_hbl    = regs[5'h05];
	assign reg_slip   = regs[5'h06];
	assign reg_apdma  = regs[5'h07];
	assign reg_pmbase = regs[5'h08];
	assign reg_albase = regs[5'h09];
	assign reg_opt    = regs[5'h0A];
	assign reg_mocon  = regs[5'h10];
	assign reg_pcon   = regs[5'h11];
	assign reg_grcon  = regs[5'h12];

	assign vad_enable = reg_enable[15];
	assign dma_enable = HONOUR_ENABLE14 ? (reg_enable[15] & ~reg_enable[14])
	                                    : reg_enable[15];
	assign oas_en     = reg_opt[7];

	// Reg 0A options.  Batman's steady value is 0x4410 (OPIUM, O_DCDMA,
	// OCRDTACK); the game's tile blitters toggle OAS_EN at run time.
	assign opfhsiz_pf2at = reg_opt[15];
	assign opium         = reg_opt[14];
	assign ols_en        = reg_opt[13];
	assign oslpink       = reg_opt[12];
	assign osloram       = reg_opt[11];
	assign o_dcdma       = reg_opt[10];
	assign o_dvdma       = reg_opt[9];
	assign oadroen       = reg_opt[8];
	assign ocrdwe        = reg_opt[6];
	assign ovrdtack      = reg_opt[5];
	assign ocrdtack      = reg_opt[4];

	// =====================================================================
	// The EOF reload sequencer state (starts at native frame zero (MAME baseline))
	// =====================================================================
	typedef enum logic [2:0] { EOF_IDLE, EOF_READ, EOF_WAIT, EOF_COMMIT, EOF_DRAIN } eof_state_t;
	eof_state_t eof_st;
	logic [5:0] eof_i;
    logic [15:0] eof_buf;

	// =====================================================================
	// One write port into the file: CPU or EOF reload
	// =====================================================================
	logic        wr;
	logic  [4:0] wr_a;
	logic [15:0] wr_d;

	wire cpu_wr = cpu_cs & cpu_we & (|cpu_lanes);
    wire [15:0] cpu_mask = {{8{cpu_lanes[1]}},{8{cpu_lanes[0]}}};

	// Kept outside the always_comb: Icarus does not support constant part
	// selects inside always_* processes.
	wire [4:0] eof_i_lo = eof_i[4:0];

	always_comb begin
		if (cpu_wr) begin
			wr   = 1'b1;
			wr_a = cpu_a;
			wr_d = (regs[cpu_a] & ~cpu_mask) | (cpu_din & cpu_mask);
		end else if ((eof_st == EOF_COMMIT)
		             && (!EOF_SKIP_ZERO || (eof_buf != 16'h0000))) begin
			wr   = 1'b1;
			wr_a = eof_i_lo;
			wr_d = eof_buf;
		end else begin
			wr   = 1'b0;
			wr_a = 5'd0;
			wr_d = 16'd0;
		end
	end

	// =====================================================================
	// The parameter-word decoder: one decoder, any source
	// =====================================================================
	wire        par_word = (wr & (wr_a >= 5'h10) & (wr_a <= 5'h1B)) | (ls_wr & ls_ready);
	wire [15:0] par_src  = (ls_wr & ls_ready) ? ls_d : wr_d;
	assign ls_ready = !reset && !init_reset && !cpu_wr && !wr;
    wire [3:0]  par_tag  = par_src[3:0];
	wire [8:0]  par_val  = par_src[15:7];

	always_ff @(posedge clk) begin
		if (reset || init_reset) begin
			mo_xscroll      <= 9'd0;
			playfield2_xscroll     <= 9'd0;
			playfield_xscroll_raw <= 9'd0;
			mo_yscroll      <= 9'd0;
			playfield2_yscroll     <= 9'd0;
			playfield_yscroll     <= 9'd0;
		end else if (par_word) begin
			case (par_tag)
				4'h9: mo_xscroll      <= par_val;
				4'hA: playfield2_xscroll     <= par_val;
				4'hB: playfield_xscroll_raw <= par_val;
				4'hD: mo_yscroll      <= par_val;
				4'hE: playfield2_yscroll     <= par_val;
				4'hF: playfield_yscroll     <= par_val;
				default: ;   // tags 0-8 and C have no destination
			endcase
		end
	end

	// The two playfields share one horizontal fetch pipeline, so PF2's scroll
	// includes the low three bits of the other raw scroll (MAME update_pf_xscrolls).
	// Per-layer pixel offsets are applied in batman_pf, not here.
	assign playfield_xscroll = playfield_xscroll_raw
	                   + (COUPLE_FINE ? {6'd0, playfield2_xscroll[2:0]} : 9'd0);

	// =====================================================================
	// The file itself
	// =====================================================================
	integer k;
	always_ff @(posedge clk) begin
		if (reset || init_reset) begin
			for (k = 0; k < 32; k = k + 1) regs[k] <= 16'h0000;
		end else if (wr) begin
			regs[wr_a] <= wr_d;
		end
	end

	// The attribute latches are plain registers (no double buffering seen).
	assign attr_msb_latch = regs[5'h1C][15:8];   // reg 1C, high lane
	assign attr_lsb_latch = regs[5'h1D][7:0];    // reg 1D, low lane

	// /MOBWR: a CPU or EOF write to 0x10-0x12 is passed on to the MOB, which
	// stores it but does not interpret it (the bit meanings are undocumented).
	assign mob_wr  = !(reset || init_reset) & wr & (wr_a >= 5'h10) & (wr_a <= 5'h12);
	assign mob_sel = wr_a[1:0];

	// Reg 03 arms the scanline comparator; any write to reg 1E acknowledges
	// the interrupt (the data is ignored).
	assign irq_arm = !(reset || init_reset) & wr & (wr_a == 5'h03);
	assign irq_ack = !(reset || init_reset) & wr & (wr_a == 5'h1E);
    assign irq_target = wr_d[8:0];
    assign irq_word = wr_d;
    always_ff @(posedge clk) begin
        if(reset || init_reset) palette_bank <= 1'b0;
        else if(wr && wr_a == 5'h0A) palette_bank <= ~wr_d[10];
    end

	// =====================================================================
	// The EOF sequencer
	// =====================================================================
	localparam logic [5:0] EOFLAST = EOF_LAST[5:0];

	always_ff @(posedge clk) begin
		if (init_reset) begin
            eof_st <= EOF_IDLE; eof_i <= 0; eof_buf <= 0; eof_req <= 0;
        end else if(reset) begin
            eof_buf <= 0;
            if((eof_st == EOF_WAIT || eof_st == EOF_DRAIN) && eof_req && !eof_ack)
                eof_st <= EOF_DRAIN;
            else begin eof_st <= EOF_IDLE; eof_req <= 0; end
		end else begin
			case (eof_st)
				EOF_IDLE: begin
					eof_req <= 1'b0;
					if (eof_start) begin
						eof_i  <= 6'd0;
						eof_st <= EOF_READ;
					end
				end
				EOF_READ: begin
					// A CPU write wins the file's write port, so hold off.
					if (!cpu_wr) begin
						eof_req <= 1'b1;
						eof_st  <= EOF_WAIT;
					end
				end
                EOF_WAIT: if(eof_ack) begin
                    eof_buf <= eof_data;
                    eof_req <= 1'b0;
                    eof_st <= EOF_COMMIT;
                end
                EOF_COMMIT: if(!cpu_wr) begin
                    if(eof_i == EOFLAST) eof_st <= EOF_IDLE;
                    else begin eof_i <= eof_i + 6'd1; eof_st <= EOF_READ; end
                end
                EOF_DRAIN: if(eof_ack) begin eof_req <= 0; eof_st <= EOF_IDLE; end
                default: eof_st <= EOF_IDLE;
			endcase
		end
	end
	assign eof_idx = eof_i;

	// =====================================================================
	// Readback
	// =====================================================================
	// Reg 00 reads the beam: vpos clamped to255, |0x4000 when clamped line exceeds239.
	wire [7:0]  vclamp = vpos[8] ? 8'hFF : vpos[7:0];
	wire [15:0] beam   = {1'b0, (vclamp > 8'd239), 6'b0, vclamp};

	always_comb begin
		if (cpu_a == 5'h00)          cpu_dout = beam;
		else if (READBACK_SHADOW)    cpu_dout = regs[cpu_a];
		else                         cpu_dout = 16'h0000;
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// Bits 6-4 of a parameter word are unused by the format.
	wire _unused = &{1'b0, regs[5'h1C][7:0], regs[5'h1D][15:8],
	                 par_src[6:4], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
