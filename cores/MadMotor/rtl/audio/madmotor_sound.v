/*  This file is part of JTCORES. GPLv3. See jtcninja_game.v header.

    Sound subsystem for Data East cninja.cpp (Joe & Mac).
    Modeled on cores/{midres,slyspy}/hdl/*_snd.v (same HuC6280 family).

    Sound crystal 32.220 MHz:
      HuC6280 (H6280)  @ /8  = 4.0275 MHz   (modules/HUC6280, full 21-bit MMU map)
      YM2203  (jt03)   @ /8  = 4.0275 MHz   -> opn + psg
      YM2151 (ikaopm)  @ /9  = 3.58   MHz   -> opm_l/opm_r, IRQ -> H6280 IRQ2
      MSM6295 (jt6295) @ /32 = 1.0069 MHz   -> pcm1  (oki1, 256kB)
      MSM6295 (jt6295) @ /16 = 2.0138 MHz   -> pcm2  (oki2, 512kB, banked by YM2151 CT)

    HuC6280 physical sound_map (doc/cninja.cpp ::sound_map):
      000000-00ffff  program ROM            A[20:16]==0
      100000-100001  YM2203                  A[20] & A[19:16]==0
      110000-110001  YM2151                  A[20] & A[19:16]==1
      120000-120001  OKI1                    A[20] & A[19:16]==2
      130000-130001  OKI2                    A[20] & A[19:16]==3
      140000         soundlatch_r            A[20] & A[19:16]==4
      1f0000-1f1fff  work RAM (8kB)          A[20:16]==0x1f

    soundlatch write (DECO104) -> H6280 IRQ1 (set on snd_irq, cleared on latch read).
    YM2151 IRQ -> H6280 IRQ2.
*/
module madmotor_sound(
    input tri0 bandit,
    output [20:0] debug_address,
    output [7:0] debug_data,
    output debug_chip_write,
    output [3:0] native_sample,

    input             rst,
    input             clk,
    input             cen_snd,    // HuC6280 CLK input (6x the CPU rate)
    input             cen_opn,    // YM2203 4.0275MHz
    input             cen_opm,    // YM2151 ~3.58MHz
    input             cen_oki1,   // ~1MHz
    input             cen_oki2,   // ~2MHz
    input             dseal,      // Dark Seal OKI2 is 256kB, NOT banked
    // From main CPU via DECO 104
    input      [ 7:0] latch,
    input             snd_irq,    // 1-clk pulse on soundlatch write
    // Work RAM 0x1f0000-0x1f1fff (mem.yaml bram: sndram)
    output     [12:0] sndram_addr,
    output     [ 7:0] sndram_din,
    output            sndram_we,
    input      [ 7:0] sndram_dout,
    // Program ROM (BA0)
    output     [15:0] rom_addr,
    output reg        rom_cs,
    input      [ 7:0] rom_data,
    input             rom_ok,
    // OKI #1 sample ROM (BA2)
    output     [17:0] oki1_addr,
    output            oki1_cs,
    input      [ 7:0] oki1_data,
    input             oki1_ok,
    // OKI #2 sample ROM (BA2)
    output     [18:0] oki2_addr,
    output            oki2_cs,
    input      [ 7:0] oki2_data,
    input             oki2_ok,
    // Mixed channels (YM2151 is stereo)
    output signed [15:0] opn,
    output     [ 9:0] psg,
    output signed [15:0] opm_l,
    output signed [15:0] opm_r,
    output signed [13:0] pcm1,
    output signed [13:0] pcm2
);

wire oki1_native,oki2_native;
reg [1:0] oki_sample_delay;
always @(posedge clk)begin
    if(rst)oki_sample_delay<=0;
    else oki_sample_delay<={oki2_native,oki1_native};
end
assign native_sample[3:2]=oki_sample_delay;
wire [20:0] A,huc_A;
wire [7:0] huc_dout,bandit_dout,opl_dout;
wire [15:0] bandit_A;
wire huc_wrn,huc_rdn,bandit_wr,bandit_rd,opl_irqn;
wire signed [15:0] huc_opml,huc_opmr,opl_sound;
wire [1:0] huc_sample;
wire opl_sample;
assign A=bandit?{5'd0,bandit_A}:huc_A;
assign dout=bandit?bandit_dout:huc_dout;
assign wrn=bandit?~bandit_wr:huc_wrn;
assign rdn=bandit?~bandit_rd:huc_rdn;
assign opm_l=bandit?opl_sound:huc_opml;
assign opm_r=bandit?opl_sound:huc_opmr;
assign native_sample[1:0]=bandit?{2{opl_sample}}:huc_sample;
jt65c02 bandit_cpu(
    .rst(rst || !bandit),.clk(clk),.cen(cen_snd && bandit),
    .irq(!opn_irqn || !opl_irqn),.nmi(irq1),.wr(bandit_wr),.rd(bandit_rd),
    .addr(bandit_A),.din(din),.dout(bandit_dout));
jtopl2 bandit_opl(
    .rst(rst || !bandit),.clk(clk),.cen(cen_opm && bandit),
    .din(dout),.addr(A[0]),.cs_n(!(bandit && opm_cs)),.wr_n(wrn),
    .dout(opl_dout),.irq_n(opl_irqn),.snd(opl_sound),.sample(opl_sample));
wire [ 7:0] dout, opn_dout, opm_dout, oki1_dout, oki2_dout;
reg  [ 7:0] din;
wire        wrn, rdn, SX;
wire        ce, cek_n, ce7_n, cer_n;
reg         rom_good;
reg         ram_cs, opn_cs, opm_cs, oki1_dev, oki2_dev, latch_cs;
wire        opn_irqn, opm_irqn;
reg         irq1;
wire        oki1_wrn = ~(oki1_dev & ~wrn);
wire        oki2_wrn = ~(oki2_dev & ~wrn);

// HuC6280 shares clk; GLOBAL_CE replaces the sibling clock gate.

assign debug_address=A;
assign debug_data=dout;
assign debug_chip_write=(opn_cs|opm_cs|oki1_dev|oki2_dev)&~wrn;
assign rom_addr = A[15:0];
assign sndram_we   = ram_cs & ~wrn;
assign sndram_addr = A[12:0];
assign sndram_din  = dout;
assign oki1_cs  = 1'b1;     // jt6295 fetches ROM continuously
assign oki2_cs  = 1'b1;

// ---- device decode (latched on SX, cleared on CE) ----
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        rom_cs<=0; ram_cs<=0; opn_cs<=0; opm_cs<=0;
        oki1_dev<=0; oki2_dev<=0; latch_cs<=0;
    end else begin
        if(bandit) begin
            rom_cs<=A[15] && (bandit_rd || bandit_wr);
            ram_cs<=A[15:11]==0 && (bandit_rd || bandit_wr);
            opn_cs<=A[15:1]==15'h0400 && (bandit_rd || bandit_wr);
            opm_cs<=A[15:1]==15'h0800 && (bandit_rd || bandit_wr);
            oki1_dev<=A[15:0]==16'h3800 && (bandit_rd || bandit_wr);
            oki2_dev<=0;
            latch_cs<=A[15:0]==16'h3000 && bandit_rd;
        end else if( SX ) begin
            rom_cs   <= A[20:16]==5'd0;
            opn_cs   <= A[20:1]==20'h80000;
            opm_cs   <= A[20:1]==20'h88000;
            oki1_dev <= A[20:1]==20'h90000;
            oki2_dev <= A[20:1]==20'h98000;
            latch_cs <= A[20:1]==20'ha0000;
            ram_cs   <= A[20:13]==8'hf8;       // 1f0000-1f1fff
        end else if( ce ) begin
            rom_cs<=0; ram_cs<=0; opn_cs<=0; opm_cs<=0;
            oki1_dev<=0; oki2_dev<=0; latch_cs<=0;
        end
    end
end

always @(posedge clk) begin
    rom_good <= !rom_cs || rom_ok;
    din <= ram_cs   ? sndram_dout :
           opn_cs   ? opn_dout  :
           opm_cs   ? (bandit?opl_dout:opm_dout)  :
           oki1_dev ? oki1_dout :
           oki2_dev ? oki2_dout :
           latch_cs ? latch     :
           rom_cs   ? rom_data  : 8'hff;
end

// soundlatch -> IRQ1: set on the write pulse, cleared when the CPU reads the latch
wire latch_rd = latch_cs & ~rdn;
always @(posedge clk, posedge rst) begin
    if( rst ) irq1 <= 0;
    else begin
        if( snd_irq )       irq1 <= 1;
        else if( latch_rd ) irq1 <= 0;
    end
end


HUC6280 u_huc(
    .CLK    ( clk      ),
    .GLOBAL_CE( cen_snd && !bandit ),
    .RST_N  ( ~(rst || bandit) ),
    .WAIT_N ( rom_good ),
    .SX     ( SX       ),
    .A      ( huc_A    ),
    .DI     ( din      ),
    .DO     ( huc_dout ),
    .WR_N   ( huc_wrn  ),
    .RD_N   ( huc_rdn  ),
    .RDY    ( 1'b1     ),
    .NMI_N  ( 1'b1     ),
    .IRQ1_N ( ~irq1    ),    // soundlatch
    .IRQ2_N ( opm_irqn ),    // YM2151
    .CE     ( ce       ),
    .CEK_N  ( cek_n    ),
    .CE7_N  ( ce7_n    ),
    .CER_N  ( cer_n    ),
    .PRE_RD (          ),
    .PRE_WR (          ),
    .HSM    (          ),
    .O      (          ),
    .K      ( 8'd0     ),
    .VDCNUM ( 1'b0     ),
    .AUD_LDATA(        ),
    .AUD_RDATA(        )
);

// ---- YM2203 (FM + PSG) ----
jt03 u_2203(
    .rst    ( rst      ),
    .clk    ( clk      ),
    .cen    ( cen_opn  ),
    .din    ( dout     ),
    .addr   ( A[0]     ),
    .cs_n   ( ~opn_cs  ),
    .wr_n   ( wrn      ),
    .dout   ( opn_dout ),
    .irq_n  ( opn_irqn ),     // not routed to the CPU on cninja
    .IOA_in ( 8'd0     ),
    .IOB_in ( 8'd0     ),
    .IOA_out(          ),
    .IOB_out(          ),
    .IOA_oe (          ),
    .IOB_oe (          ),
    .psg_A  (          ),
    .psg_B  (          ),
    .psg_C  (          ),
    .fm_snd ( opn      ),
    .psg_snd( psg      ),
    .snd    (          ),
    .snd_sample(       ),
    .debug_view(       )
);

// ---- YM2151 (stereo); CT1 banks OKI2 ----
// IKAOPM, the gate-accurate YM2151. cen_opm is phiM (xtal/9 = 3.58 MHz), the
// same rate jt51 took, and the wrapper inverts it into i_phiM_PCEN_n.
wire ym_ct1, ym_ct2;
madmotor_ikaopm u_2151(
    .rst    ( rst      ),
    .clk    ( clk      ),
    .cen    ( cen_opm  ),
    .cs_n   ( ~(opm_cs && !bandit) ),
    .rd_n   ( rdn      ),
    .wr_n   ( wrn      ),
    .a0     ( A[0]     ),
    .din    ( dout     ),
    .dout   ( opm_dout ),
    .ct1    ( ym_ct1   ),
    .ct2    ( ym_ct2   ),
    .irq_n  ( opm_irqn ),
    .left   ( huc_opml ),
    .right  ( huc_opmr ),
    .left_sample(huc_sample[0]),.right_sample(huc_sample[1])
);

// ---- OKI #1 (256kB) ----
jt6295 #(.INTERPOL(0),.SAMPLE(1)) u_oki1(
    .rst     ( rst      ),
    .clk     ( clk      ),
    .cen     ( cen_oki1 ),
    .ss      ( 1'b1     ),     // PIN7_HIGH
    .wrn     ( oki1_wrn ),
    .din     ( dout     ),
    .dout    ( oki1_dout),
    .rom_addr( oki1_addr),
    .rom_data( oki1_data),
    .rom_ok  ( oki1_ok  ),
    .sound   ( pcm1     ),
    .sample  ( oki1_native )
);

`ifdef SIMULATION
// Sound heartbeat: peak amplitudes + soundlatch commands. The cninja attract is
// silent (only the YM2151 tempo timer) until the main CPU sends a play command
// (~frame 1106 in MAME, cmd 0x14) which drives the YM2203 music. Verified vs MAME.
integer opnw=0, opmw=0, oki1w=0, latchN=0;
reg [31:0] dbgcnt=0;
reg [15:0] opn_max=0, opm_max=0, pcm1_max=0;
reg        latch_rd_l=0;
function [15:0] absv(input signed [15:0] v); absv = v[15]? -v : v; endfunction
always @(posedge clk) begin
    if( opn_cs   & ~wrn ) opnw  = opnw +1;
    if( opm_cs   & ~wrn ) opmw  = opmw +1;
    if( oki1_dev & ~wrn ) oki1w = oki1w+1;
    latch_rd_l <= latch_rd;
    if( latch_rd & ~latch_rd_l ) begin latchN=latchN+1; $display("[SND] latch cmd=%02X (#%0d)", latch, latchN); end
    if( absv(opn)   > opn_max  ) opn_max  <= absv(opn);
    if( absv(opm_l) > opm_max  ) opm_max  <= absv(opm_l);
    if( absv({2'd0,pcm1}) > pcm1_max ) pcm1_max <= absv({2'd0,pcm1});
    dbgcnt <= dbgcnt+1;
    if( dbgcnt[21:0]==0 )
        $display("[SND] opnw=%0d opmw=%0d oki1w=%0d | MAX opn=%0d opm=%0d pcm1=%0d",
                 opnw, opmw, oki1w, opn_max, opm_max, pcm1_max);
end
`endif

// ---- OKI #2: cninja 512kB banked by YM2151 CT1; darkseal 256kB, NOT banked
// (its YM2151 has no CT handler) so the CT1 bit must not reach the address. ----
wire [17:0] oki2_a;
assign oki2_addr = { ~dseal & ym_ct1, oki2_a };   // cninja set_rom_bank(data&1)
jt6295 #(.INTERPOL(0),.SAMPLE(1)) u_oki2(
    .rst     ( rst      ),
    .clk     ( clk      ),
    .cen     ( cen_oki2 ),
    .ss      ( 1'b1     ),
    .wrn     ( oki2_wrn ),
    .din     ( dout     ),
    .dout    ( oki2_dout),
    .rom_addr( oki2_a   ),
    .rom_data( oki2_data),
    .rom_ok  ( oki2_ok  ),
    .sound   ( pcm2     ),
    .sample  ( oki2_native )
);

endmodule
