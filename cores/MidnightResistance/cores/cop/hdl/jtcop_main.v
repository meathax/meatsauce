/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 24-9-2021 */

module jtcop_main #(
    parameter PROGRAM_CACHE=1,
    parameter PROGRAM_CACHE_BITS=16,
    parameter FAST_LOCAL_ACK=1
)(
    input              rst,
    input              clk,

    input              LVBL,
    input              LHBL,
    // external interrupts
    input              nexirq,

    // Bus signals
    output      [15:0] cpu_dout,
    output      [18:1] cpu_addr,
    output             UDSWn,
    output             LDSWn,
    output             RnW,

    // BA register reads
    input       [15:0] ba0_dout,
    input       [15:0] ba1_dout,
    input       [15:0] ba2_dout,

    // MCU/SUB CPU
    input       [15:0] mcu_dout,
    output reg  [15:0] mcu_din,
    output     [5:0]   sec,         // bit 2 is unused
    input              sec2,        // this is the bit 2!

    // sound
    output             snreq,
    output reg [7:0]   snd_latch,

    // Palette
    output reg [ 7:0]  prisel,
    output     [ 1:0]  pal_cs,
    input      [15:0]  pal_dout,

    // BAC06 chips
    output             fmode_cs,
    output             fsft_cs,
    output             fmap_cs,
    output             bmode_cs,
    output             bsft_cs,
    output             bmap_cs,
    output             cmode_cs,
    output             csft_cs,
    output             cmap_cs,

    // HuC6820 protection
    input       [ 7:0] huc_dout,
    output             huc_cs,      // shared memory with HuC6820

    // Objects
    output             obj_cs,       // called MIX in the schematics
    output             obj_copy,     // called *DM in the schematics
    output reg         mixpsel,      // related to the OBJ buffer DMA function
    input       [15:0] obj_dout,

    // cabinet I/O
    input       [ 8:0] joystick1,
    input       [ 8:0] joystick2,
    input       [15:0] joyana1,
    input       [15:0] joyana2,
`ifdef MIDRES_TWINSTICK
    // Twin-stick additions: left sticks (movement), OSD options, NVRAM channel
    input       [15:0] joyana_l1,
    input       [15:0] joyana_l2,
    input       [ 1:0] aim_speed,
    input       [ 1:0] aim_deadzone,
    input              aim_autofire,
    input              gun_autofire,
    input              pcb_slowdown,
    input              ioctl_ram,
    input              ioctl_wr,
    input       [26:0] ioctl_addr,
    input       [ 7:0] ioctl_dout,
    output      [ 7:0] ioctl_din,
    input              osd_open,
    output             score_upload_request,
`endif
    input       [ 1:0]  dial_x,
    input       [ 1:0]  dial_y,

    input       [ 1:0] cab_1p,
    input       [ 1:0] coin,
    input              service,

    // RAM access
    output             ram_cs,
    input       [15:0] ram_data,   // coming from VRAM or RAM
    input              ram_ok,

    output             rom_cs,
    input       [15:0] rom_data,
    input              rom_ok,

    // DIP switches
    input              dip_pause,
    input              dip_test,
    input    [7:0]     dipsw_a,
    input    [7:0]     dipsw_b,

    // Debug
    input      [7:0]   st_addr,
    output reg [7:0]   st_dout
);
`ifndef NOMAIN
wire [23:1] A;
//wire        BERRn;
wire [ 2:0] FC;
reg  [ 2:0] IPLn;
wire        /*BRn, BGACKn,*/ BGn;
wire        ASn, UDSn, LDSn, BUSn, VPAn;
reg  [15:0] cpu_din;
wire        disp_cs, sysram_cs, cblk, vint_clr,
            eep_cs,
            prisel_cs, mixpsel_cs,
            nexrm1,         // used on Heavy Barrel PCB for the track balls
            nexrm0_cs;      // a signal on Robocop sch. unused. Reused for SlySpy for the protection IC
reg         secirq, vint;
wire        ok_dly;
wire        pre_ram_cs;
wire        decoded_rom_cs;
wire [15:0] cpu_rom_data;
wire        cpu_rom_ok;
wire        cpu_cen, cpu_cenb;
wire [1:0]  dir, step;
wire [ 2:0] read_cs;
wire [ 7:0] track_dout;
wire [15:0] fave;
reg         LVBL_l, sec2_l;

reg  [15:0] cab_dout;
reg  [11:0] rotary1, rotary2;

`ifdef SIMULATION
wire [23:0] A_full = {A,1'b0};
`endif

assign UDSWn = RnW | UDSn;
assign LDSWn = RnW | LDSn;
assign BUSn  = ASn | (LDSn & UDSn);
assign VPAn  = ~&{ FC, ~ASn };
assign cpu_addr = A[18:1];

`ifdef MIDRES_TWINSTICK
generate if(PROGRAM_CACHE) begin : gen_program_cache
    // A private registered ROM cache removes repeated instruction/data reads
    // from the shared sound/program SDRAM bank. The backend retains real waits.
    midres_program_cache #(.INDEX_BITS(PROGRAM_CACHE_BITS),.EARLY_HIT(FAST_LOCAL_ACK)) u_cache(
        .clk(clk), .rst(rst), .cs(decoded_rom_cs && !BUSn),
        .addr(A[18:1]), .dout(cpu_rom_data), .ok(cpu_rom_ok),
        .backend_cs(rom_cs), .backend_data(rom_data), .backend_ok(rom_ok)
    );
end else begin : gen_program_passthrough
    assign rom_cs=decoded_rom_cs;
    assign cpu_rom_data=rom_data;
    assign cpu_rom_ok=rom_ok;
end endgenerate
`else
assign rom_cs=decoded_rom_cs;
assign cpu_rom_data=rom_data;
assign cpu_rom_ok=rom_ok;
`endif

`ifdef MIDRES_TWINSTICK
// The native 16 KiB work RAM has no video/MCU reader. Keep it off the
// shared SDRAM/tilemap bank; out-of-range donor aliases still use SDRAM.
wire fast_ram_sel = sysram_cs && A[16:14]==0;
wire [15:0] fast_ram_data;
wire fast_ram_ok;
midres_work_ram u_fast_ram(
    .clk(clk), .rst(rst), .cs(fast_ram_sel && !BUSn),
    .addr(A[13:1]), .rnw(RnW), .dsn({UDSn,LDSn}),
    .din(cpu_dout), .dout(fast_ram_data), .ok(fast_ram_ok)
);
assign pre_ram_cs = (sysram_cs && !fast_ram_sel) | fsft_cs | fmap_cs |
`else
assign pre_ram_cs = sysram_cs | fsft_cs | fmap_cs |
`endif
                                bsft_cs | bmap_cs |
                                cmap_cs | csft_cs;
assign ram_cs   = ~BUSn & pre_ram_cs;

always @(posedge clk) begin
    case( st_addr[5:4] )
        0: st_dout = st_addr[0] ? {4'd0,rotary1[11:8]} : rotary1[7:0];
        1: st_dout = {dial_y, dial_x, step, dir };
        2: st_dout = st_addr[0] ? fave[15:8] : fave[7:0]; // 10,000kHz = 2710 in hex
        default: st_dout = 0;
    endcase
end

always @(*) begin
    if( vint )
        IPLn = ~3'd6;   // 001 = 1
    else if( secirq )   // active high
        IPLn = ~3'd5;   // 010 = 2
    else if( !nexirq )  // active low
        IPLn = ~3'd4;   // 011 = 3
    else
        IPLn = ~3'd0;
end

// NB: this module is different for jtmidres
jtcop_decoder u_decoder(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .A          ( A         ),
    .ASn        ( ASn       ),
    .RnW        ( RnW       ),
    .LVBL       ( LVBL      ),
    .LVBL_l     ( LVBL_l    ),
    .sec2       ( sec2      ),
    .service    ( service   ),
    .coin ( coin),
    .rom_cs     ( decoded_rom_cs ),
    .eep_cs     ( eep_cs    ),
    .prisel_cs  ( prisel_cs ),
    .mixpsel_cs ( mixpsel_cs),
    .nexin_cs   (           ),      // this pin C15 of connector 2. It's unconnected in all games
    .nexout_cs  (           ),      // Connector 2, pin A16: unused
    .nexrm1     ( nexrm1    ),      // used on Heavy Barrel PCB for the track balls
    .disp_cs    ( disp_cs   ),
    .sysram_cs  ( sysram_cs ),
    .vint_clr   ( vint_clr  ),
    .cblk       ( cblk      ),
    .read_cs    ( read_cs   ),
    // BAC06 chips
    .fmode_cs   ( fmode_cs  ),
    .fsft_cs    ( fsft_cs   ),
    .fmap_cs    ( fmap_cs   ),
    .bmode_cs   ( bmode_cs  ),
    .bsft_cs    ( bsft_cs   ),
    .bmap_cs    ( bmap_cs   ),
    .nexrm0_cs  ( nexrm0_cs ),
    .cmode_cs   ( cmode_cs  ),
    .csft_cs    ( csft_cs   ),
    .cmap_cs    ( cmap_cs   ),
    // Object
    .obj_cs     ( obj_cs    ),      // called MIX in the schematics
    .obj_copy   ( obj_copy  ),      // called *DM in the schematics
    // Palette
    .pal_cs     ( pal_cs    ),
    // HuC6820 protection
    .huc_cs     ( huc_cs    ),      // shared memory with HuC6820
    // sound
    .snreq      ( snreq     ),
    // MCU/SUB CPU
    .sec        ( sec       )       // bit 2 is unused
);

`ifdef SIMULATION
    integer f;
    initial begin
        f=$fopen("prisel.bin","rb");
        $fread(prisel,f);
        $fclose(f);
    end
`endif

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        vint    <= 0;
        secirq  <= 0;
        LVBL_l  <= 0;
        sec2_l  <= 0;
        snd_latch <= 0;
        mcu_din <= 0;
        // prisel  <= 0;
        mixpsel <= 0;
    end else begin
        LVBL_l <= LVBL;
        if( vint_clr )
            vint <= 0;
        else if( !LVBL && LVBL_l ) vint <= 1;

        if( snreq )
            snd_latch <= cpu_dout[7:0];

        // MCU
        if( sec[0] )    // CPU writes
            mcu_din <= cpu_dout;

        sec2_l <= sec2; // CPU reads
        if( sec[1] ) // clear interrupt
            secirq <= 0;
        else if( !sec2_l && sec2 )
            secirq  <= 1;

        // Colour mixer
        if( prisel_cs ) begin
        `ifndef SLYSPY
            prisel <= cpu_dout[7:0];
        `else
            prisel <= {7'd0,cpu_dout[7]}; // SlySpy uses a single bit
        `endif
        end

        // Object DMA
        if( mixpsel_cs ) mixpsel <= cpu_dout[0];
    end
end

`ifdef MIDRES_TWINSTICK
wire [8:0] joy1_m, joy2_m;
wire [11:0] rotary1_m, rotary2_m;
wire        score_hit;
wire [15:0] score_rd;
`else
wire [8:0] joy1_m = joystick1, joy2_m = joystick2;
wire [11:0] rotary1_m = rotary1, rotary2_m = rotary2;
`endif

// Cabinet inputs
`ifndef DEC1
    always @(posedge clk) begin
        cab_dout <= 16'hffff;
        if( read_cs[0] )
            cab_dout <= { joystick2[7:0], joystick1[7:0] };
        if( read_cs[1] )
            cab_dout <= { 8'hff,
                            ~LVBL,
                            service,
                            coin,
                            cab_1p,
                            joystick2[8],
                            joystick1[8] };
        if( read_cs[2] )
            cab_dout <= { dipsw_b, dipsw_a };
    end
`else
    always @(posedge clk) begin
        cab_dout <= 16'hffff;
        if( read_cs[0] )
            cab_dout <= {
                cab_1p[1], joy2_m[6:0],
                cab_1p[0], joy1_m[6:0]
            };
        if( read_cs[1] )
            cab_dout <= {   ~12'h0,
                            ~LVBL,
                            service,
                            coin };
        if( read_cs[2] )
            cab_dout <= { dipsw_b, dipsw_a };
        if( read_cs==7 ) begin
            cab_dout[15:12] <= 4'hf;
            cab_dout[11: 0] <= A[1] ? ~rotary2_m : ~rotary1_m;
        end
    end
`endif

// input multiplexer
reg  [1:0] track_xrst, track_yrst;
wire [1:0] track_cf;
reg  [3:0] track_cs;
wire [7:0] track0_dout, track1_dout;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        rotary1 <= 0;
        rotary2 <= 0;
    end else begin
        if(step[0]&~dir[0])
            rotary1 <= rotary1==0 ? 12'd1 :
`ifdef MIDRES_TWINSTICK
                {rotary1[10:0],rotary1[11]};
`else
                (rotary1<<1);
`endif
        if(step[0]& dir[0])
            rotary1 <= rotary1==0 ? 12'h800 :
`ifdef MIDRES_TWINSTICK
                {rotary1[0],rotary1[11:1]};
`else
                (rotary1>>1);
`endif

        if(step[1]&~dir[1])
            rotary2 <= rotary2==0 ? 12'd1 :
`ifdef MIDRES_TWINSTICK
                {rotary2[10:0],rotary2[11]};
`else
                (rotary2<<1);
`endif
        if(step[1]& dir[1])
            rotary2 <= rotary2==0 ? 12'h800 :
`ifdef MIDRES_TWINSTICK
                {rotary2[0],rotary2[11:1]};
`else
                (rotary2>>1);
`endif
    end
end

jt4701_axis #(.HOTONE(1),.SLOWN(7)) u_axisx(
    .clk        ( clk       ),
    .rst        ( rst       ),
    .sigin      ( dial_x    ),
    .flag_clrn  ( 1'b1      ),
    .flagn      (           ),
    .axis       (           ),
    .dir        ( dir[0]    ),
    .step       ( step[0]   )
);

jt4701_axis #(.HOTONE(1),.SLOWN(7)) u_axisy(
    .clk        ( clk       ),
    .rst        ( rst       ),
    .sigin      ( dial_y    ),
    .flag_clrn  ( 1'b1      ),
    .flagn      (           ),
    .axis       (           ),
    .dir        ( dir[1]    ),
    .step       ( step[1]   )
);

`ifdef SLYSPY
reg [7:0] prot_dout;
reg [7:0] prot_cpy;

always @(posedge clk) begin
    if( sysram_cs && A[12:1]==12'h14 && !RnW ) prot_cpy <= cpu_dout[7:0];
    prot_dout <= 0;
    if( nexrm0_cs ) case( A[3:1] )
            1: prot_dout <= 'h13;
            3: prot_dout <= 'h2;
            6: prot_dout <= prot_cpy; // random value
        endcase
end
`endif

always @(posedge clk) begin
`ifdef MIDRES_TWINSTICK
    cpu_din <=  fast_ram_sel ? (score_hit ? score_rd : fast_ram_data) :
                ram_cs    ? (score_hit ? score_rd : ram_data) :
`else
    cpu_din <=  ram_cs    ? ram_data :
`endif
                decoded_rom_cs ? cpu_rom_data :
                pal_cs!=0 ? pal_dout :
                obj_cs    ? obj_dout :
                read_cs!=0? cab_dout :
                fmode_cs  ? ba0_dout :
                bmode_cs  ? ba1_dout :
                cmode_cs  ? ba2_dout :
                sec[1]    ? mcu_dout :
                huc_cs    ? { 8'hff, huc_dout }  :
                track_cs[0] ? {8'hff, track0_dout } :
                track_cs[1] ? {8'hff, track1_dout } :
                track_cs[2] ? {track_cf[0], track_cf[1], 2'b11, ~rotary2 } :
                track_cs[3] ? { 4'hf, ~rotary1 } :
        `ifdef SLYSPY
                nexrm0_cs ? {8'h0, prot_dout} :
        `endif
                16'hffff;
end

reg  disp_busy;
`ifdef MIDRES_TWINSTICK
wire bus_cs    = pal_cs!=0 || pre_ram_cs || decoded_rom_cs || fast_ram_sel;
wire [2:0] ok_cs, ok_in;
assign ok_cs = { fast_ram_sel, decoded_rom_cs, pre_ram_cs };
assign ok_in = { fast_ram_ok, cpu_rom_ok, ram_ok };
// Local memories already return registered, address-qualified data. The CPU
// input register and registered DTACK advance together on the next clock;
// another okdly stage would withhold an otherwise legal S4 sampling phase.
wire bus_busy = |{ fast_ram_sel & ~(FAST_LOCAL_ACK ? fast_ram_ok : ok_dly),
                  decoded_rom_cs & ~((FAST_LOCAL_ACK && PROGRAM_CACHE) ? cpu_rom_ok : ok_dly),
                  pre_ram_cs & ~ok_dly, disp_cs & disp_busy };
`else
wire bus_cs    = pal_cs!=0 || pre_ram_cs || rom_cs;
wire [1:0] ok_cs, ok_in;
assign ok_cs = { rom_cs, pre_ram_cs };
assign ok_in = { rom_ok, ram_ok };
wire bus_busy  = |{ rom_cs & ~ok_dly, pre_ram_cs & ~ok_dly, disp_cs & disp_busy };
`endif
wire bus_legit = disp_cs;

jtframe_okdly #(.W(`ifdef MIDRES_TWINSTICK 3 `else 2 `endif)) u_okdly(
    .rst    ( rst    ),
    .clk    ( clk    ),
    .cs     ( ok_cs  ),
    .ok     ( ok_in  ),
    .ok_dly ( ok_dly )
);

// Memory access to the display area gets locked until a blank starts
// during a blank, each access has a 2 clock delay until DTACKn is generated
// in practice, this means that each access has a 1 clock penalty, as the
// 1st clock after /AS goes low is lost by the CPU anyway
wire       disp_blank = disp_cs & (~LVBL | ~LHBL);
reg        disp_blank_l, disp_cs_l;
reg  [1:0] disp_bs_cnt;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        disp_busy   <= 0;
        disp_bs_cnt <= 0;
    end else begin
        disp_blank_l <= disp_blank;
        disp_cs_l    <= disp_cs;
        // display request
        if( disp_cs & ~disp_cs_l )
            disp_busy    <= 1;

        // display ack
        if( disp_blank & ~disp_blank_l) begin
            disp_bs_cnt <= 2'b11;
        end else if( cpu_cen ) begin
            disp_bs_cnt <= disp_bs_cnt >> 1;
        end
        // display data good
        if( disp_bs_cnt==0 )
            disp_busy <= 0;
    end
end

// Track ball
`ifndef NOTRACKBALL
    always @* begin
        track_cs   = 0;
        track_xrst = 0;
        track_yrst = 0;
        if( nexrm1 ) begin
            if( RnW && !A[6] ) begin
                case( A[4:3] )
                    0: track_cs[3] = 1; // rotary control
                    1: track_cs[2] = 1; // 4701's flags read in bits 15:14
                    2: track_cs[0] = 1;
                    3: track_cs[1] = 1;
                endcase
            end else if( !RnW && A[6] ) begin
                case( A[4:3] )
                    0: track_xrst[0]=1;
                    1: track_yrst[0]=1;
                    2: track_xrst[1]=1;
                    3: track_yrst[1]=1;
                endcase
            end
        end
    end

    jt4701_dialemu_2axis u_track0(
        .rst    ( rst           ),
        .clk    ( clk           ),
        .LHBL   ( LHBL          ),
        .inc    ( {1'b0, ~joystick1[6] } ),
        .dec    ( {1'b0, ~joystick1[7] } ),
        .x_rst  ( track_xrst[0] ),
        .y_rst  ( track_yrst[0] ),
        .uln    ( A[1]          ),
        .cs     ( track_cs[0]   ),
        .xn_y   ( A[2]          ),
        .cfn    ( track_cf[0]   ),
        .sfn    (               ),
        .dout   ( track0_dout   )
    );

    jt4701_dialemu_2axis u_track1(
        .rst    ( rst           ),
        .clk    ( clk           ),
        .LHBL   ( LHBL          ),
        .inc    ( {1'b0, ~joystick2[6] } ),
        .dec    ( {1'b0, ~joystick2[7] } ),
        .x_rst  ( track_xrst[1] ),
        .y_rst  ( track_yrst[1] ),
        .uln    ( A[1]          ),
        .cs     ( track_cs[1]   ),
        .xn_y   ( A[2]          ),
        .cfn    ( track_cf[1]   ),
        .sfn    (               ),
        .dout   ( track1_dout   )
    );
`else
    assign track0_dout = 0;
    assign track1_dout = 0;
    assign track_cf    = 3;
    initial track_cs   = 0;
`endif

`ifdef MIDRES_TWINSTICK
// Default: opportunistic 24 MHz with no unpayable recovery debt. PCB slowdown
// selects the measured 10 MHz schedule and repays artificial backend waits.
wire [6:0] main_num = pcb_slowdown ? 7'd5 : 7'd12;
localparam MAIN_RECOVERY = 2;
`else
localparam [6:0] MHZ = `ifdef DEC1 12 `else 10 `endif ; // 12 MHz used on Midnight Resistance
localparam MAIN_RECOVERY = 1;
`endif

wire DTACKn;

jtframe_68kdtack_cen #(.W(8),.RECOVERY(MAIN_RECOVERY)) u_dtack(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cpu_cen    ( cpu_cen   ),
    .cpu_cenb   ( cpu_cenb  ),
    .bus_cs     ( bus_cs    ),
    .bus_busy   ( bus_busy  ),
    .bus_legit  ( bus_legit ),
    .bus_ack    ( 1'b0      ),
    .ASn        ( ASn       ),
    .DSn        ({UDSn,LDSn}),
`ifdef MIDRES_TWINSTICK
    .num        ( main_num  ),
    .recovery_en( pcb_slowdown ),
`else
    .num        ( MHZ>>1    ),  // numerator
    .recovery_en( 1'b1      ),
`endif
    .den        ( 8'd24     ),  // denominator
    .DTACKn     ( DTACKn    ),
    .wait2      ( 1'b0      ),
    .wait3      ( 1'b0      ),
    // Frequency report
    .fave       ( fave      ),
    .fworst     (           )
);

jtframe_m68k u_cpu(
    .clk        ( clk         ),
    .rst        ( rst         ),
    .cpu_cen    ( cpu_cen     ),
    .cpu_cenb   ( cpu_cenb    ),

    // Buses
    .eab        ( A           ),
    .iEdb       ( cpu_din     ),
    .oEdb       ( cpu_dout    ),


    .eRWn       ( RnW         ),
    .LDSn       ( LDSn        ),
    .UDSn       ( UDSn        ),
    .ASn        ( ASn         ),
    .VPAn       ( VPAn        ),
    .FC         ( FC          ),

    .BERRn      ( 1'b1        ),
    // Bus arbitrion
    .RESETn     (             ),
    .HALTn      ( dip_pause   ),
    .BRn        ( 1'b1        ),
    .BGACKn     ( 1'b1        ),
    .BGn        ( BGn         ),

    .DTACKn     ( DTACKn      ),
    .IPLn       ( IPLn        ) // VBLANK
);

`ifdef MIDRES_TWINSTICK
// ---------------------------------------------------------------------------
// Twin-stick input and score additions (see docs/MIDRES_AIM_CONTRACT.md).
// ---------------------------------------------------------------------------
wire        wr_commit, score_wr;
wire [1:0]  aim_strobe;
wire [2:0]  aim_a1, aim_a2;
wire [5:0]  score_word;
midres_bus_snoop u_snoop(
    .clk        ( clk        ),
    .as_n       ( ASn        ),
    .rnw        ( RnW        ),
    .dtack_n    ( DTACKn     ),
    .uds_n      ( UDSn       ),
    .lds_n      ( LDSn       ),
    .sysram_cs  ( sysram_cs  ),
    .a          ( A          ),
    .data       ( cpu_dout   ),
    .wr_commit  ( wr_commit  ),
    .aim_strobe ( aim_strobe ),
    .aim_a1     ( aim_a1     ),
    .aim_a2     ( aim_a2     ),
    .score_hit  ( score_hit  ),
    .score_word ( score_word ),
    .score_wr   ( score_wr   )
);

wire [1:0] aim_fire;
wire [3:0] aim_move1, aim_move2;
midres_aim_controls #(.CLOCK_HZ(`JTFRAME_MCLK)) u_aim(
    .clk          ( clk           ),
    .reset        ( rst           ),
    .paused       ( ~dip_pause    ),
    .left1        ( joyana_l1     ),
    .left2        ( joyana_l2     ),
    .right1       ( joyana1       ),
    .right2       ( joyana2       ),
    .speed        ( aim_speed     ),
    .deadzone     ( aim_deadzone  ),
    .autofire     ( aim_autofire  ),
    .actual_strobe( aim_strobe    ),
    .actual1      ( aim_a1        ),
    .actual2      ( aim_a2        ),
    .manual_cw    ( step &  dir   ),
    .manual_ccw   ( step & ~dir   ),
    .legacy1      ( rotary1       ),
    .legacy2      ( rotary2       ),
    .rotary1      ( rotary1_m     ),
    .rotary2      ( rotary2_m     ),
    .move1        ( aim_move1     ),
    .move2        ( aim_move2     ),
    .fire         ( aim_fire      ),
    .owned        (               )
);
wire [1:0] gun_fire;
wire [3:0] directions1=joystick1[3:0] & ~aim_move1;
wire [3:0] directions2=joystick2[3:0] & ~aim_move2;
midres_weapon_fire u_gun1(
    .clk(clk),.reset(rst),.paused(~dip_pause),.enable(gun_autofire),
    .physical_fire(~joystick1[4]),.stick_fire(aim_fire[0]),.up(~directions1[0]),
    .commit(wr_commit && sysram_cs && !UDSn),.address(A),.data(cpu_dout[15:8]),
    .fire(gun_fire[0]));
midres_weapon_fire #(.PLAYER2(1)) u_gun2(
    .clk(clk),.reset(rst),.paused(~dip_pause),.enable(gun_autofire),
    .physical_fire(~joystick2[4]),.stick_fire(aim_fire[1]),.up(~directions2[0]),
    .commit(wr_commit && sysram_cs && !UDSn),.address(A),.data(cpu_dout[15:8]),
    .fire(gun_fire[1]));
assign joy1_m = { joystick1[8:5], ~gun_fire[0], directions1 };
assign joy2_m = { joystick2[8:5], ~gun_fire[1], directions2 };

// High-score table 0x1026EA..0x102739 (80 bytes), mirrored from completed CPU writes
midres_score_nvram u_score(
    .clk          ( clk           ),
    .reset        ( rst           ),
    .wr_commit    ( score_wr      ),
    .wr_word      ( score_word    ),
    .wr_uds       ( ~UDSn         ),
    .wr_lds       ( ~LDSn         ),
    .wr_data      ( cpu_dout      ),
    .rd_word      ( score_word    ),
    .rd_data      ( score_rd      ),
    .ioctl_ram    ( ioctl_ram     ),
    .ioctl_wr     ( ioctl_wr      ),
    .ioctl_addr   ( ioctl_addr    ),
    .ioctl_dout   ( ioctl_dout    ),
    .ioctl_din    ( ioctl_din     ),
    .osd_open     ( osd_open      ),
    .upload_request( score_upload_request ),
    .restored_out (               )
);
`endif
`else
    // sound
    // reg [7:0]   snd_aux;
    // always @* snd_latch = snd_aux;

    jtframe_sim_sndcmd #(.CMDCNT(8)) u_sndcmd(
        .rst  ( rst     ),
        .clk  ( clk     ),
        .irq  ( snreq   ),
        .lvbl ( LVBL    ),
        .cmd  (snd_latch),
        .frame_list( { 16'd4, 16'd67, 16'd73,16'd76,16'd79, 16'd341, 16'd695, 16'd747 }  ),
        .cmd_list  ( {  8'h1,  8'h5e,  8'h01, 8'h3a, 8'h5e,   8'h59,  8'h0d,   8'h59  }  )
    );

    assign  cpu_dout = 0,
            cpu_addr = 0,
            UDSWn    = 1,
            LDSWn    = 1,
            RnW      = 0,
            sec      = 0,
            pal_cs   = 0,
            fmode_cs = 0,
            fsft_cs  = 0,
            fmap_cs  = 0,
            bmode_cs = 0,
            bsft_cs  = 0,
            bmap_cs  = 0,
            cmode_cs = 0,
            csft_cs  = 0,
            cmap_cs  = 0,
            huc_cs   = 0,
            obj_cs   = 0,
            obj_copy = 0,
            ram_cs   = 0,
            rom_cs   = 0;
`ifdef MIDRES_TWINSTICK
    assign ioctl_din = 0, score_upload_request = 0;
`endif
    initial begin
        mcu_din = 0;
        prisel  = 0;
        mixpsel = 0;
        st_dout = 0;
    end
`endif
endmodule

`ifdef MIDRES_TWINSTICK
// Single-clock, byte-enabled work RAM. DS delimits each transaction, including
// TAS's two transfers under one AS. One registered read precedes acknowledgement;
// held selects never repeat a write. Game reset preserves RAM, as on the PCB.
module midres_work_ram(
    input clk, rst, cs,
    input [12:0] addr,
    input rnw,
    input [1:0] dsn,
    input [15:0] din,
    output reg [15:0] dout,
    output ok
);
    reg [7:0] hi[0:8191];
    reg [7:0] lo[0:8191];
    reg done;
    wire take = cs && !done && !rst;
    assign ok = cs && done && !rst;
    always @(posedge clk) begin
        if(rst || !cs) done <= 0;
        else done <= 1;
        if(take) begin
            dout <= {hi[addr],lo[addr]};
            if(!rnw && !dsn[1]) hi[addr] <= din[15:8];
            if(!rnw && !dsn[0]) lo[addr] <= din[7:0];
        end
    end
endmodule

// Direct-mapped, read-only word cache using synchronous data/tag RAMs. The
// registered lookup follows the BloodBros rom_cache donor; level acknowledgments,
// cancellation and sequential tag invalidation match this core's JTFRAME port.
// The backend's data_ok must identify its current live address, as required by
// the existing CPU ROM port. No address or clock is changed at that boundary.
module midres_program_cache #(parameter INDEX_BITS=16, EARLY_HIT=1)(
    input clk, rst, cs,
    input [17:0] addr,
    output [15:0] dout,
    output ok,
    output backend_cs,
    input [15:0] backend_data,
    input backend_ok
);
    localparam TAG_BITS=18-INDEX_BITS;
    localparam CLEAR=0, IDLE=1, CHECK=2, ARM=3, FETCH=4, READY=5;
    reg [2:0] state;
    reg [INDEX_BITS-1:0] clear_index;
    reg [17:0] pending;
    reg settle;
    reg [15:0] data_mem[0:(1<<INDEX_BITS)-1];
    reg [TAG_BITS:0] tag_mem[0:(1<<INDEX_BITS)-1];
    reg [15:0] read_data;
    reg [TAG_BITS:0] read_tag;
    reg [15:0] response_data;
    wire tag_hit = read_tag=={1'b1,pending[17:INDEX_BITS]};
    wire current_request = cs && addr==pending;
    wire fill = state==FETCH && !settle && backend_ok && current_request && !rst;
    assign backend_cs = !rst && current_request && (state==ARM || state==FETCH);
    assign ok = !rst && current_request && (state==READY || (EARLY_HIT && state==CHECK && tag_hit));
    assign dout = (EARLY_HIT && state==CHECK && tag_hit) ? read_data : response_data;

    // Reset clears metadata one word per clock rather than resetting RAM cells
    // or a large bank of validity flops. The CPU waits during this cold scrub.
    always @(posedge clk) begin
        read_data <= data_mem[addr[INDEX_BITS-1:0]];
        read_tag <= tag_mem[addr[INDEX_BITS-1:0]];
        if(!rst) begin
            if(state==CLEAR) tag_mem[clear_index] <= 0;
            else if(fill) begin
                data_mem[pending[INDEX_BITS-1:0]] <= backend_data;
                tag_mem[pending[INDEX_BITS-1:0]] <= {1'b1,pending[17:INDEX_BITS]};
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin state<=CLEAR;clear_index<=0;settle<=0;end
        else if(state==CLEAR) begin
            clear_index<=clear_index+1'b1;
            if(&clear_index) state<=IDLE;
        end else if(state!=IDLE && !current_request) state<=IDLE;
        else case(state)
            IDLE: if(cs) begin pending<=addr;state<=CHECK;end
            CHECK: if(tag_hit) begin
                response_data<=read_data;state<=READY;
            end else begin state<=ARM;settle<=1;end
            ARM: state<=FETCH;
            FETCH: if(settle) settle<=0;
                   else if(backend_ok) begin response_data<=backend_data;state<=READY;end
            READY: ;
            default: state<=CLEAR;
        endcase
    end
endmodule
`endif
