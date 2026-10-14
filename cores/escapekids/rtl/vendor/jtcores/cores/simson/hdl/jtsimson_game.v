/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 23-7-2023 */

module jtsimson_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

/* verilator tracing_off */
wire [ 7:0] snd2main, video_dump, fm_dout;
wire        cpu_cen, snd_irq, rmrd, rst8, init;
wire        pal_we, pal_bank, fm_irqn,
            cpu_we, tilesys_cs, objsys_cs, pcu_cs, objcha_n;
wire        cpu_rnw, cpu_irqn, cpu_firqn, cpu_nmin, dma_bsy, snd_wrn, mono, objreg_cs, main_fmcs;
wire        video_bank, k053252_cs;
wire [ 7:0] k053252_dout;
wire [ 7:0] tilesys_dout, objsys_dout,
            obj_dout, pal_dout, cpu_dout,
            st_main, st_video, st_snd;
wire        tilesys_rom_dtack, main_cpu_ok;
wire        dbg_trap_seen, dbg_berr_l, dbg_buserror, dbg_dtack, dbg_eep_rdy;
wire [15:0] cpu_addr;
wire [15:0] dbg_pc, dbg_pcbad, dbg_trap_pc, dbg_trap_addr,
            dbg_hist_pc, dbg_hist_addr, dbg_accept_count;
wire [ 7:0] dbg_cpu_din, dbg_aupper, dbg_last_op,
            dbg_trap_op, dbg_trap_data, dbg_trap_flags,
            dbg_hist_op, dbg_hist_data, dbg_hist_flags, dbg_cpu_reg_byte;
wire [ 7:0] core_red, core_green, core_blue;
wire [ 3:0] dbg_hist_index, dbg_reg_index, dbg_hist_wr;
wire [12:0] ram_addr;
wire [18:0] main_rom_addr;
wire [15:0] video_dumpa;
wire [20:0] pcm_raw_addr_a, pcm_raw_addr_b, pcm_raw_addr_c, pcm_raw_addr_d;
wire [20:0] pcm_start_a, pcm_start_b, pcm_start_c, pcm_start_d;
wire [20:0] pcm_schedule_a, pcm_schedule_b, pcm_schedule_c, pcm_schedule_d;
wire [20:0] pcm_fill_addr_a, pcm_fill_addr_b,
            pcm_fill_addr_c, pcm_fill_addr_d;
wire [ 7:0] pcm_prefetch_data_a, pcm_prefetch_data_b,
            pcm_prefetch_data_c, pcm_prefetch_data_d;
wire [ 3:0] pcm_prefetch_ok, pcm_prefetch_warm,
            pcm_prefetch_underrun, pcm_sample, pcm_bsy, pcm_reverse;
wire        pcm_raw_cs_a, pcm_raw_cs_b, pcm_raw_cs_c, pcm_raw_cs_d;
wire [ 3:0] pcm_fill_cs;
wire [ 6:0] input_joystick1, input_joystick2,
            input_joystick3, input_joystick4;
reg  [ 3:0] pcm_bsy_d;
reg         simson, paroda, vendetta, suratk, esckids, cabinet_2p;

`ifdef SIMULATION
// JTFRAME normally delivers the profile header before the game is released
// from reset.  Give the diagnostic harness the same donor-default state during
// the short pre-header interval so ROM requests cannot propagate X values.
initial begin
    simson     = 1'b1;
    paroda     = 1'b0;
    vendetta   = 1'b0;
    suratk     = 1'b0;
    esckids    = 1'b0;
    cabinet_2p = 1'b0;
end
`endif

assign debug_view = 8'd0;
assign ram_din    = cpu_dout;
assign ioctl_din  = video_dump;
assign video_dumpa= ioctl_addr[15:0]-16'h80;
assign red        = core_red;
assign green      = core_green;
assign blue       = core_blue;
// The generated memory wrapper shares main_addr between the program-ROM
// request slot and work BRAM.  Present the ROM address only for an active ROM
// request; all other CPU cycles expose the physical 13-bit work-RAM address.
// This preserves the ROM request path while preventing stack accesses from
// aliasing to the last program fetch address.
assign main_addr  = main_cs ? main_rom_addr : { 6'd0, ram_addr };
assign pcma_addr  = esckids ? pcm_fill_addr_a : pcm_raw_addr_a;
assign pcmb_addr  = esckids ? pcm_fill_addr_b : pcm_raw_addr_b;
assign pcmc_addr  = esckids ? pcm_fill_addr_c : pcm_raw_addr_c;
assign pcmd_addr  = esckids ? pcm_fill_addr_d : pcm_raw_addr_d;
assign pcma_cs    = esckids ? pcm_fill_cs[0] : pcm_raw_cs_a;
assign pcmb_cs    = esckids ? pcm_fill_cs[1] : pcm_raw_cs_b;
assign pcmc_cs    = esckids ? pcm_fill_cs[2] : pcm_raw_cs_c;
assign pcmd_cs    = esckids ? pcm_fill_cs[3] : pcm_raw_cs_d;
assign pcm_schedule_a = pcm_bsy_d[0] ? pcm_raw_addr_a : pcm_start_a;
assign pcm_schedule_b = pcm_bsy_d[1] ? pcm_raw_addr_b : pcm_start_b;
assign pcm_schedule_c = pcm_bsy_d[2] ? pcm_raw_addr_c : pcm_start_c;
assign pcm_schedule_d = pcm_bsy_d[3] ? pcm_raw_addr_d : pcm_start_d;

escape_kids_rom_ready u_main_rom_ready(
    .clk        ( clk48         ),
    .rst        ( rst48         ),
    .enable     ( esckids       ),
    .rom_cs     ( main_cs       ),
    .rom_addr   ( main_rom_addr ),
    .rom_ok     ( main_ok       ),
    .cpu_rom_ok ( main_cpu_ok   )
);

// Escape Kids maps the three OSD action buttons to Run, Super Jump and
// Auto Run.  Keep the convenience behavior in a project-owned wrapper so
// all other JTCORES profiles retain their donor input path unchanged.
escape_kids_auto_run u_auto_run(
    .clk          ( clk48          ),
    .rst          ( rst48          ),
    .enable       ( esckids         ),
    .lvbl         ( LVBL            ),
    .joystick1    ( joystick1       ),
    .joystick2    ( joystick2       ),
    .joystick3    ( joystick3       ),
    .joystick4    ( joystick4       ),
    .joystick1_out( input_joystick1 ),
    .joystick2_out( input_joystick2 ),
    .joystick3_out( input_joystick3 ),
    .joystick4_out( input_joystick4 )
);

`ifdef SIMULATION
always @(posedge clk48) begin
    if( !rst48 && !main_cs && main_addr[12:0] !== ram_addr )
        $error("Work RAM address bridge mismatch ram=%04h main=%04h",ram_addr,main_addr[12:0]);
    // Check each channel's own schedule/start relationship against its own
    // keyon edge only. The four PCM channels are independent (separate MMR
    // start-address registers per K053260 channel; schematic p8/p20 show no
    // shared bsy/address gating across channels). A channel that is already
    // mid-playback naturally has schedule==raw_addr while its own start
    // register can independently hold a different (already-advanced, or
    // already-reprogrammed-for-next-sound) address; that mismatch is normal
    // and must not be blamed on a different channel's unrelated keyon edge.
    // Regression coverage before this fix only ever key-on'd all four
    // channels in the same cycle (single 0x0F write to reg 0x28), so the
    // any-channel-OR/check-all-channels form never saw a staggered keyon
    // while a sibling channel was already playing; real gameplay audio
    // (background loop + independent one-shot SFX) does exactly that.
    if( !rst48 && esckids ) begin
        if( pcm_bsy[0] && !pcm_bsy_d[0] && pcm_schedule_a !== pcm_start_a )
            $error("PCM keyon schedule left programmed start before address phase settled (ch A)");
        if( pcm_bsy[1] && !pcm_bsy_d[1] && pcm_schedule_b !== pcm_start_b )
            $error("PCM keyon schedule left programmed start before address phase settled (ch B)");
        if( pcm_bsy[2] && !pcm_bsy_d[2] && pcm_schedule_c !== pcm_start_c )
            $error("PCM keyon schedule left programmed start before address phase settled (ch C)");
        if( pcm_bsy[3] && !pcm_bsy_d[3] && pcm_schedule_d !== pcm_start_d )
            $error("PCM keyon schedule left programmed start before address phase settled (ch D)");
    end
end
`endif

escape_kids_pcm_prefetch u_pcm_prefetch(
    .clk        ( clk48                 ),
    .rst        ( rst48                 ),
    .enable     ( esckids               ),
    .ch0_addr   ( pcm_raw_addr_a        ),
    .ch1_addr   ( pcm_raw_addr_b        ),
    .ch2_addr   ( pcm_raw_addr_c        ),
    .ch3_addr   ( pcm_raw_addr_d        ),
    .ch0_schedule ( pcm_schedule_a         ),
    .ch1_schedule ( pcm_schedule_b         ),
    .ch2_schedule ( pcm_schedule_c         ),
    .ch3_schedule ( pcm_schedule_d         ),
    .ch0_pin     ( pcm_start_a           ),
    .ch1_pin     ( pcm_start_b           ),
    .ch2_pin     ( pcm_start_c           ),
    .ch3_pin     ( pcm_start_d           ),
    .ch_cs      ( {pcm_raw_cs_d,pcm_raw_cs_c,
                   pcm_raw_cs_b,pcm_raw_cs_a} ),
    .ch_sample  ( pcm_sample             ),
    .ch_bsy     ( pcm_bsy                ),
    .ch_reverse ( pcm_reverse            ),
    .ch0_data   ( pcm_prefetch_data_a   ),
    .ch1_data   ( pcm_prefetch_data_b   ),
    .ch2_data   ( pcm_prefetch_data_c   ),
    .ch3_data   ( pcm_prefetch_data_d   ),
    .ch_ok      ( pcm_prefetch_ok       ),
    .warm       ( pcm_prefetch_warm     ),
    .mem0_addr  ( pcm_fill_addr_a       ),
    .mem1_addr  ( pcm_fill_addr_b       ),
    .mem2_addr  ( pcm_fill_addr_c       ),
    .mem3_addr  ( pcm_fill_addr_d       ),
    .mem_cs     ( pcm_fill_cs           ),
    .mem0_data  ( pcma_data             ),
    .mem1_data  ( pcmb_data             ),
    .mem2_data  ( pcmc_data             ),
    .mem3_data  ( pcmd_data             ),
    .mem_ok     ( {pcmd_ok,pcmc_ok,pcmb_ok,pcma_ok} ),
    .underrun   ( pcm_prefetch_underrun )
);

always @(posedge clk48) begin
    if( rst48 ) pcm_bsy_d <= 4'd0;
    else        pcm_bsy_d <= pcm_bsy;
end

always @(posedge clk) begin
    if( header && prog_we ) begin
        if( prog_addr[1:0]==0 ) begin
            simson   <= prog_data[2:0]==0;
            paroda   <= prog_data[2:0]==1;
            vendetta <= prog_data[2:0]==2;
            esckids  <= prog_data==8'h03;
            suratk   <= prog_data[2:0]==4;
        end
        if( prog_addr[1:0]==1 )
            cabinet_2p <= esckids && prog_data[0];
`ifdef SIMULATION
        if( prog_addr[1:0]==0 && prog_data!=8'h03 &&
                prog_data[2:0]!=0 && prog_data[2:0]!=1 &&
                prog_data[2:0]!=2 && prog_data[2:0]!=4 )
            $error("Unsupported JTFRAME profile header byte %02X",prog_data);
        if( esckids && prog_addr[1:0]==1 && prog_data[7:1]!=0 )
            $error("Escape Kids header reserved bits are non-zero: %02X",prog_data);
        if( esckids && prog_addr[1:0]>1 && prog_data!=0 )
            $error("Escape Kids reserved header byte %0d is non-zero: %02X",prog_addr[1:0],prog_data);
`endif
    end
end

/* verilator tracing_off */
jtsimson_main u_main(
    .rst            ( rst48         ),
    .clk            ( clk48         ),
    .cen_ref        ( cen24         ), // should it be cen12?
    .cpu_cen        ( cpu_cen       ),

    .simson         ( simson        ),
    .paroda         ( paroda        ),
    .vendetta       ( vendetta      ),
    .esckids        ( esckids       ),
    .cabinet_2p     ( cabinet_2p    ),
    .suratk         ( suratk        ),
    // YM2151 (only suratk)
    .fm_cs          ( main_fmcs     ),
    .fm_dout        ( fm_dout       ),
    .fm_irqn        ( fm_irqn       ),

    .cpu_addr       ( cpu_addr      ),
    .cpu_dout       ( cpu_dout      ),
    .cpu_we         ( cpu_we        ),

    .rom_addr       ( main_rom_addr ),
    .rom_data       ( main_data     ),
    .rom_cs         ( main_cs       ),
    .rom_ok         ( main_cpu_ok   ),
    // RAM
    .ram_addr       ( ram_addr      ),
    .ram_we         ( ram_we        ),
    .ram_dout       ( ram_dout      ),
    // cabinet I/O
    .cab_1p         ( cab_1p        ),
    .coin           ( coin          ),
    .joystick1      ( input_joystick1 ),
    .joystick2      ( input_joystick2 ),
    .joystick3      ( input_joystick3 ),
    .joystick4      ( input_joystick4 ),
    .service        ( service       ),

    // From video
    .rst8           ( rst8          ),
    .LVBL           ( LVBL          ),
    .irq_n          ( cpu_irqn      ),
    .cpu_firqn      ( cpu_firqn     ),
    .cpu_nmin       ( cpu_nmin      ),
    .dma_bsy        ( dma_bsy       ),

    .tilesys_dout   ( tilesys_dout  ),
    .tilesys_rom_dtack ( tilesys_rom_dtack ),
    .objsys_dout    ( objsys_dout   ),
    .pal_dout       ( pal_dout      ),
    // To video
    .objsys_cs      ( objsys_cs     ),
    .objreg_cs      ( objreg_cs     ),
    .tilesys_cs     ( tilesys_cs    ),
    .pcu_cs         ( pcu_cs        ),
    .init           ( init          ),
    .rmrd           ( rmrd          ),
    .pal_bank       ( pal_bank      ),
    .pal_we         ( pal_we        ),
    .objcha_n       ( objcha_n      ),
    .video_bank     ( video_bank    ),
    .k053252_cs     ( k053252_cs    ),
    .k053252_dout   ( k053252_dout  ),
    // To sound
    .snd_irq        ( snd_irq       ),
    .snd2main       ( snd2main      ),
    .snd_wrn        ( snd_wrn       ),
    .mono           ( mono          ),
    // EEPROM
    .nv_addr        ( nvram_addr    ),
    .nv_dout        ( nvram_dout    ),
    .nv_din         ( nvram_din     ),
    .nv_we          ( nvram_we      ),
    // DIP switches
    .dip_test       ( dip_test      ),
    .dip_pause      ( dip_pause     ),
    .dipsw          ( dipsw[23:0]   ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .st_dout        ( st_main       ),
    .dbg_hist_sel   ( dbg_hist_index ),
    .dbg_reg_sel    ( dbg_reg_index ),
    .dbg_pc         ( dbg_pc        ),
    .dbg_pcbad      ( dbg_pcbad     ),
    .dbg_trap_pc    ( dbg_trap_pc   ),
    .dbg_trap_addr  ( dbg_trap_addr ),
    .dbg_hist_pc    ( dbg_hist_pc   ),
    .dbg_hist_addr  ( dbg_hist_addr ),
    .dbg_accept_count( dbg_accept_count ),
    .dbg_hist_wr    ( dbg_hist_wr    ),
    .dbg_cpu_din    ( dbg_cpu_din    ),
    .dbg_aupper     ( dbg_aupper      ),
    .dbg_last_op    ( dbg_last_op   ),
    .dbg_trap_op    ( dbg_trap_op   ),
    .dbg_trap_data  ( dbg_trap_data ),
    .dbg_trap_flags ( dbg_trap_flags),
    .dbg_hist_op    ( dbg_hist_op   ),
    .dbg_hist_data  ( dbg_hist_data ),
    .dbg_hist_flags ( dbg_hist_flags),
    .dbg_cpu_reg_byte( dbg_cpu_reg_byte ),
    .dbg_trap_seen  ( dbg_trap_seen ),
    .dbg_berr_l     ( dbg_berr_l    ),
    .dbg_buserror   ( dbg_buserror  ),
    .dbg_dtack      ( dbg_dtack     ),
    .dbg_eep_rdy    ( dbg_eep_rdy  )
);

jtsimson_sound u_sound(
    .rst        ( rst48         ),
    .clk        ( clk48         ),
    .cen_fm     ( cen_fm        ),
    .cen_fm2    ( cen_fm2       ),

    .simson     ( simson        ),
    .suratk     ( suratk        ),
    // communication with main CPU
    .snd_irq    ( snd_irq       ),
    .main_dout  ( cpu_dout      ),
    .main_din   ( snd2main      ),
    .main_addr  ( cpu_addr[0]   ),
    .main_rnw   ( snd_wrn       ),
    .mono       ( mono          ),
    .voice_mute ( esckids && status[11] ),
    // YM2151 (only suratk)
    .main_fmcs  ( main_fmcs     ),
    .fm_dout    ( fm_dout       ),
    .fm_irqn    ( fm_irqn       ),
    // ROM
    .rom_addr   ( snd_addr      ),
    .rom_cs     ( snd_cs        ),
    .rom_data   ( snd_data      ),
    .rom_ok     ( snd_ok        ),
    // ADPCM ROM
    .pcma_addr  ( pcm_raw_addr_a ),
    .pcma_dout  ( esckids ? pcm_prefetch_data_a : pcma_data ),
    .pcma_cs    ( pcm_raw_cs_a   ),
    .pcma_ok    ( esckids ? pcm_prefetch_ok[0] : pcma_ok ),

    .pcmb_addr  ( pcm_raw_addr_b ),
    .pcmb_dout  ( esckids ? pcm_prefetch_data_b : pcmb_data ),
    .pcmb_cs    ( pcm_raw_cs_b   ),
    .pcmb_ok    ( esckids ? pcm_prefetch_ok[1] : pcmb_ok ),

    .pcmc_addr  ( pcm_raw_addr_c ),
    .pcmc_dout  ( esckids ? pcm_prefetch_data_c : pcmc_data ),
    .pcmc_cs    ( pcm_raw_cs_c   ),
    .pcmc_ok    ( esckids ? pcm_prefetch_ok[2] : pcmc_ok ),

    .pcmd_addr  ( pcm_raw_addr_d ),
    .pcmd_dout  ( esckids ? pcm_prefetch_data_d : pcmd_data ),
    .pcmd_cs    ( pcm_raw_cs_d   ),
    .pcmd_ok    ( esckids ? pcm_prefetch_ok[3] : pcmd_ok ),
    .pcm_sample ( pcm_sample    ),
    .pcm_bsy    ( pcm_bsy       ),
    .pcm_reverse( pcm_reverse   ),
    .pcma_start ( pcm_start_a   ),
    .pcmb_start ( pcm_start_b   ),
    .pcmc_start ( pcm_start_c   ),
    .pcmd_start ( pcm_start_d   ),
    // Sound output
    .snd_l      ( snd_l         ),
    .snd_r      ( snd_r         ),
    // Debug
    .snd_en     ( snd_en        ),
    .debug_bus  ( debug_bus     ),
    .st_dout    ( st_snd        )
);

/* verilator tracing_on */
jtsimson_video #(
    .GX975      ( 1 ),
    .EXT_TIMING ( 1 )
) u_video (
    .rst            ( rst           ),
    .rst8           ( rst8          ),
    .clk            ( clk           ),

    .simson         ( simson        ),
    .paroda         ( paroda        ),
    .esckids        ( esckids       ),
    .suratk         ( suratk        ),
    .video_bank     ( video_bank    ),
    .k053252_cs     ( k053252_cs    ),
    .k053252_dout   ( k053252_dout  ),

    // base video
    .pxl_cen        ( pxl_cen       ),
    .pxl2_cen       ( pxl2_cen      ),
    .lhbl           ( LHBL          ),
    .lvbl           ( LVBL          ),
    .hs             ( HS            ),
    .vs             ( VS            ),
    .flip           ( dip_flip      ),

    // GFX - CPU interface
    .cpu_addr       ( cpu_addr      ),
    .cpu_dout       ( cpu_dout      ),
    .cpu_we         ( cpu_we        ),

    .pal_dout       ( pal_dout      ),
    .tilesys_dout   ( tilesys_dout  ),
    .tilesys_rom_dtack ( tilesys_rom_dtack ),
    .objsys_dout    ( objsys_dout   ),

    .pal_bank       ( pal_bank      ),
    .pal_we         ( pal_we        ),
    .pcu_cs         ( pcu_cs        ),
    .tilesys_cs     ( tilesys_cs    ),
    .objsys_cs      ( objsys_cs     ),
    .objreg_cs      ( objreg_cs     ),

    // control
    .rmrd           ( rmrd          ),
    .objcha_n       ( objcha_n      ),
    .cpu_irqn       ( cpu_irqn      ),
    .cpu_firqn      ( cpu_firqn     ),
    .cpu_nmin       ( cpu_nmin      ),
    .dma_bsy        ( dma_bsy       ),

    // SDRAM
    .lyra_addr      ( lyra_addr     ),
    .lyrb_addr      ( lyrb_addr     ),
    .lyrf_addr      ( lyrf_addr     ),
    .lyro_addr      ( lyro_addr     ),
    .lyra_data      ( lyra_data     ),
    .lyrb_data      ( lyrb_data     ),
    .lyro_data      ( lyro_data     ),
    .lyrf_data      ( lyrf_data     ),
    .lyrf_cs        ( lyrf_cs       ),
    .lyra_cs        ( lyra_cs       ),
    .lyrb_cs        ( lyrb_cs       ),
    .lyro_cs        ( lyro_cs       ),
    .lyra_ok        ( lyra_ok       ),
    .lyro_ok        ( lyro_ok       ),
    // pixels
    .red            ( core_red      ),
    .green          ( core_green    ),
    .blue           ( core_blue     ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .ioctl_addr     ( video_dumpa   ),
    .ioctl_din      ( video_dump    ),
    .ioctl_ram      ( ioctl_ram     ),
    .gfx_en         ( gfx_en        ),
    .st_dout        ( st_video      )
);

endmodule
