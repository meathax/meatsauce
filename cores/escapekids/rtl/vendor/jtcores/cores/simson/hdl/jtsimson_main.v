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
    Date: 5-5-2023 */

module jtsimson_main(
    input               rst,
    input               clk,
    input               cen_ref,
    output              cpu_cen,

    input               paroda,
    input               simson,
    input               vendetta,
    input               esckids,
    input               cabinet_2p,
    input               suratk,

    output      [ 7:0]  cpu_dout,
    output      [15:0]  cpu_addr,
    output reg          init,

    // FM - only suratk
    input       [ 7:0]  fm_dout,
    output reg          fm_cs,
    input               fm_irqn,

    output reg  [18:0]  rom_addr,
    input       [ 7:0]  rom_data,
    output reg          rom_cs,
    input               rom_ok,
    // RAM
    output      [12:0]  ram_addr,
    output              ram_we,
    output              cpu_we,
    input       [ 7:0]  ram_dout,
    // cabinet I/O
    input       [ 3:0]  cab_1p,
    input       [ 3:0]  coin,
    input       [ 6:0]  joystick1,
    input       [ 6:0]  joystick2,
    input       [ 6:0]  joystick3,
    input       [ 6:0]  joystick4,
    input               service,

    // From video
    input               rst8,
    input               LVBL,
    input               irq_n,  // from tile map
    input               cpu_firqn,  // from K052109
    input               cpu_nmin,   // from K052109
    input               dma_bsy,

    input      [7:0]    tilesys_dout, objsys_dout,
    input               tilesys_rom_dtack,
    input      [7:0]    pal_dout,

    // To video
    output reg          rmrd,
    output              pal_we,
    output reg          pal_bank,
    output reg          pcu_cs,
    output reg          tilesys_cs,
    output reg          objsys_cs,
    output reg          objreg_cs,
    output reg          objcha_n,
    output reg          video_bank,
    output reg          k053252_cs,
    input       [ 7:0]  k053252_dout,
    // To sound
    output reg          snd_irq,
    output              snd_wrn,
    output reg          mono,
    input       [ 7:0]  snd2main,
    // EEPROM
    output      [ 6:0]  nv_addr,
    input       [ 7:0]  nv_dout,
    output      [ 7:0]  nv_din,
    output              nv_we,

    // DIP switches
    input               dip_test,
    input               dip_pause,
    input       [23:0]  dipsw,          // used by Parodius
    // Debug
    input       [ 7:0]  debug_bus,
    output reg  [ 7:0]  st_dout,
    input       [ 3:0]  dbg_hist_sel,
    input       [ 3:0]  dbg_reg_sel,
    output      [15:0]  dbg_pc,
    output      [15:0]  dbg_pcbad,
    output      [15:0]  dbg_trap_pc,
    output      [15:0]  dbg_trap_addr,
    output      [15:0]  dbg_hist_pc,
    output      [15:0]  dbg_hist_addr,
    output      [15:0]  dbg_accept_count,
    output      [ 3:0]  dbg_hist_wr,
    output      [ 7:0]  dbg_cpu_din,
    output      [ 7:0]  dbg_aupper,
    output      [ 7:0]  dbg_last_op,
    output      [ 7:0]  dbg_trap_op,
    output      [ 7:0]  dbg_trap_data,
    output      [ 7:0]  dbg_trap_flags,
    output      [ 7:0]  dbg_hist_op,
    output      [ 7:0]  dbg_hist_data,
    output      [ 7:0]  dbg_hist_flags,
    output reg  [ 7:0]  dbg_cpu_reg_byte,
    output              dbg_trap_seen,
    output              dbg_berr_l,
    output              dbg_buserror,
    output              dbg_dtack,
    output              dbg_eep_rdy
);
`ifndef NOMAIN

wire [ 7:0] Aupper, hip_dout;
reg  [ 7:0] cpu_din, port_in;reg  [ 3:0] bank;
wire [15:0] A, pcbad;
wire        buserror;
wire        esckids_ctrl0_cs, esckids_ctrl2_cs, esckids_watchdog_cs;
reg         ram_cs, banked_cs, io_cs, pal_cs, snd_cs,
            berr_l, prog_cs, eeprom_cs, joystk_cs,
            out_cs, basel_cs, cr_cs, stsw_cs, hip_cs,
            objread_cs,
            i6n, i7n, paro_i6n, paro_i7n, suratk_i6n, suratk_i7n,
            misc_cs, paro_aux, suratk_aux, io_aux, // unpaged,
            vend_i7n, vend_i6n, vend_aux;
wire        dtack;  // to do: add delay for io_cs
reg         rst_cmb;
wire        eep_rdy, eep_do, irq_mx, firqn_ff, irqn_ff, cab_rd, firqn;
// Escape Kids has one active-low MAME SERVICE input for both the cabinet
// service controls and the physical test switch.
wire        esckids_service;
assign      esckids_service = service & dip_test;
reg         eep_di, eep_clk, eep_cs, irqen, firqen, WOC1, WOC0,
            bankr;

wire [15:0] cpu_x, cpu_y, cpu_u, cpu_s, cpu_pc;
wire [ 7:0] cpu_a, cpu_b, cpu_cc, cpu_dp;
wire        cpu_is_op;
reg  [ 7:0] last_opcode;
reg         trap_seen;
reg  [15:0] trap_pc, trap_addr;
reg  [ 7:0] trap_op, trap_data, trap_flags;
reg  [15:0] accepted_count;
reg  [ 3:0] hist_wr;
reg  [15:0] hist_pc   [0:15];
reg  [15:0] hist_addr [0:15];
reg  [ 7:0] hist_op   [0:15];
reg  [ 7:0] hist_data [0:15];
reg  [ 7:0] hist_flags[0:15];

wire accepted_cycle = cpu_cen & dtack & |{
    rom_cs, pal_cs, ram_cs, io_cs, eeprom_cs, objsys_cs, objreg_cs,
    pcu_cs, joystk_cs, basel_cs, out_cs, snd_cs, stsw_cs,
    tilesys_cs, k053252_cs, objread_cs, cr_cs,
    esckids_ctrl0_cs, esckids_ctrl2_cs, esckids_watchdog_cs
};

assign esckids_ctrl0_cs    = esckids && A == 16'h3fd0;
assign esckids_ctrl2_cs    = esckids && A == 16'h3fd2;
assign esckids_watchdog_cs = esckids && A == 16'h3fda;

assign dbg_pc           = cpu_pc;
assign dbg_pcbad        = pcbad;
assign dbg_trap_pc      = trap_pc;
assign dbg_trap_addr    = trap_addr;
assign dbg_hist_pc      = hist_pc[dbg_hist_sel];
assign dbg_hist_addr    = hist_addr[dbg_hist_sel];
assign dbg_accept_count = accepted_count;
assign dbg_hist_wr      = hist_wr;
assign dbg_cpu_din      = cpu_din;
assign dbg_aupper       = Aupper;
assign dbg_last_op      = last_opcode;
assign dbg_trap_op      = trap_op;
assign dbg_trap_data    = trap_data;
assign dbg_trap_flags   = trap_flags;
assign dbg_hist_op      = hist_op[dbg_hist_sel];
assign dbg_hist_data    = hist_data[dbg_hist_sel];
assign dbg_hist_flags   = hist_flags[dbg_hist_sel];
assign dbg_trap_seen    = trap_seen;
assign dbg_berr_l       = berr_l;
assign dbg_buserror     = buserror;
assign dbg_dtack        = dtack;
assign dbg_eep_rdy      = eep_rdy;

always @(*) begin
    case (dbg_reg_sel)
        4'h0: dbg_cpu_reg_byte = cpu_a;
        4'h1: dbg_cpu_reg_byte = cpu_b;
        4'h2: dbg_cpu_reg_byte = cpu_cc;
        4'h3: dbg_cpu_reg_byte = cpu_dp;
        4'h4: dbg_cpu_reg_byte = cpu_x[15:8];
        4'h5: dbg_cpu_reg_byte = cpu_x[7:0];
        4'h6: dbg_cpu_reg_byte = cpu_y[15:8];
        4'h7: dbg_cpu_reg_byte = cpu_y[7:0];
        4'h8: dbg_cpu_reg_byte = cpu_u[15:8];
        4'h9: dbg_cpu_reg_byte = cpu_u[7:0];
        4'ha: dbg_cpu_reg_byte = cpu_s[15:8];
        4'hb: dbg_cpu_reg_byte = cpu_s[7:0];
        4'hc: dbg_cpu_reg_byte = cpu_pc[15:8];
        4'hd: dbg_cpu_reg_byte = cpu_pc[7:0];
        4'he: dbg_cpu_reg_byte = last_opcode;
        default: dbg_cpu_reg_byte = {trap_seen, berr_l, buserror, cpu_is_op,
                                     rom_cs, rom_ok, dtack, cpu_cen};
    endcase
end

integer dbg_i;
always @(posedge clk) begin
    if (rst) begin
        last_opcode  <= 8'd0;
        trap_seen    <= 1'b0;
        trap_pc      <= 16'd0;
        trap_addr    <= 16'd0;
        trap_op      <= 8'd0;
        trap_data    <= 8'd0;
        trap_flags   <= 8'd0;
        accepted_count <= 16'd0;
        hist_wr      <= 4'd0;
        for (dbg_i=0; dbg_i<16; dbg_i=dbg_i+1) begin
            hist_pc[dbg_i]    <= 16'd0;
            hist_addr[dbg_i]  <= 16'd0;
            hist_op[dbg_i]    <= 8'd0;
            hist_data[dbg_i]  <= 8'd0;
            hist_flags[dbg_i] <= 8'd0;
        end
    end else begin
        if (accepted_cycle && cpu_is_op && !cpu_we)
            last_opcode <= cpu_din;
        if (accepted_cycle)
            accepted_count <= accepted_count + 16'd1;
        if (!trap_seen && accepted_cycle) begin
            hist_pc[hist_wr]    <= cpu_pc;
            hist_addr[hist_wr]  <= A;
            hist_op[hist_wr]    <= cpu_is_op && !cpu_we ? cpu_din : last_opcode;
            hist_data[hist_wr]  <= cpu_we ? cpu_dout : cpu_din;
            hist_flags[hist_wr] <= {1'b1, cpu_we, cpu_is_op, rom_cs,
                                    rom_ok, dtack, cpu_cen, buserror};
            hist_wr             <= hist_wr + 4'd1;
        end
        if (buserror && !trap_seen) begin
            trap_seen  <= 1'b1;
            trap_pc    <= cpu_pc;
            trap_addr  <= A;
            trap_op    <= last_opcode;
            trap_data  <= cpu_din;
            trap_flags <= {cpu_is_op, rom_cs, rom_ok, dtack,
                           cpu_cen, cpu_we, irq_mx, firqn};
        end
    end
end

// Same bound on the program-ROM handshake: a rom_ok that never arrives must
// not be able to freeze the CPU permanently (observed as a black screen or a
// frozen boot frame that only a core reload clears).
reg [15:0] romwait;
wire      rom_stall = rom_cs & ~rom_ok;

always @(posedge clk) begin
    if( rst || !rom_stall ) romwait <= 16'd0;
    else if( !(&romwait) )  romwait <= romwait + 16'd1;
end

assign dtack   = ((~rom_cs | rom_ok) | (&romwait)) & tilesys_rom_dtack;
assign ram_we  = ram_cs & cpu_we;
assign snd_wrn = suratk ? ~cpu_we : ~(snd_cs & cpu_we);
assign pal_we  = pal_cs & cpu_we;
assign cab_rd  = joystk_cs|eeprom_cs|stsw_cs|(io_cs&(paroda|suratk));
assign cpu_addr= A[15:0];
assign ram_addr= A[12:0];
assign firqn   = esckids ? cpu_firqn : (suratk ? fm_irqn : firqn_ff);

always @(*) begin
    case( debug_bus[1:0] )
        0: st_dout = Aupper;
        1: st_dout = { 7'd0, berr_l };
        2: st_dout = pcbad[7:0];
        3: st_dout = pcbad[15:8];
    endcase
end

// Decoder 053326 takes as inputs A[15:10], BK4, WOC0
// Decoder 053327 after it, takes A[10:7] for generating
// OBJCS, VRAMCS, CRAMCS, IOCS
`ifdef SIMULATION
wire [4:0] bad_cs =
        { 3'd0, rom_cs     } +
        { 3'd0, pal_cs     } +
        { 3'd0, ram_cs     } +
        { 3'd0, io_cs & ~vendetta } +
        { 3'd0, eeprom_cs  } +
        { 3'd0, objsys_cs  } +
        { 3'd0, objreg_cs  } +
        { 3'd0, pcu_cs     } +
        { 3'd0, joystk_cs  } +
        { 3'd0, basel_cs   } +
        { 3'd0, out_cs & simson } +
        { 3'd0, snd_cs     } +
        { 3'd0, snd_irq    } +
        { 3'd0, stsw_cs    } +
        { 3'd0, tilesys_cs } +
        { 3'd0, k053252_cs } +
        { 3'd0, objread_cs } +
        { 3'd0, cr_cs       } +
        { 3'd0, esckids_ctrl0_cs } +
        { 3'd0, esckids_ctrl2_cs } +
        { 3'd0, esckids_watchdog_cs };
wire none_cs = ~|{ rom_cs, pal_cs, ram_cs, io_cs, objsys_cs, cr_cs,
    objreg_cs, pcu_cs, joystk_cs, tilesys_cs, eeprom_cs, basel_cs, out_cs,
    snd_cs, snd_irq, stsw_cs, k053252_cs, objread_cs,
    esckids_ctrl0_cs, esckids_ctrl2_cs, esckids_watchdog_cs };

always @(posedge clk) begin
    if( !rst && esckids && dtack && u_cpu.u_memctrl.mem_en &&
        bad_cs > 1 )
        $error("Escape Kids decode is not one-hot: A=%04X count=%0d", A, bad_cs);
    if( !rst && esckids && dtack && u_cpu.u_memctrl.mem_en && none_cs )
        $error("Escape Kids accepted access has no chip select: A=%04X", A);
end
`endif

always @(*) begin
    rom_addr[12: 0] = A[12:0];
    k053252_cs      = 0;
    objread_cs      = 0;
    eeprom_cs       = 0;
    prog_cs         = 0;
    cr_cs           = 0;
    fm_cs           = 0;
    // used only by simpsons
    i6n = ~(A[15:10]==7 || (!init && A[15:10]==6'h1f ));
    i7n = ~((A[15:10]==7 && !WOC0) || (
            init ? (A[15:13]==1 && !WOC1) || (A[15:13]==0 && !WOC0) || A[15:12]==1 :
                    A[15:10]==7 && (WOC1  || WOC0) ));
    io_aux   = &{ ~i6n, ~i7n, A[9:7] };
    // used only by parodius
    paro_i6n   = !(A[15:10]==6'h0f);
    suratk_i6n = !(A[15:10]==6'h17);
    paro_i7n   = A[15:12]==3 || (A[15:14]==1 && (!A[13]||!bankr)) || (A[15:12]==2 && (!WOC1 || A[11]));
    suratk_i7n = bankr ? A[15:14]==2'b01 : A[15:13]==3'b011;
    paro_aux   = &{ ~paro_i6n,   A[9:7] };
    suratk_aux = &{ ~suratk_i6n, A[9:7] };
    misc_cs    = (suratk ? suratk_aux : paro_aux) && A[6:4]==3'b100;
    out_cs     = misc_cs && A[3:2]==0;
    basel_cs   = misc_cs && A[3:2]==1;
    // unpaged  = A[15:13]>=5;
    // used only by vendetta
    hip_cs  = 0;
    stsw_cs = 0;
    vend_i7n = A[15:10]==6'b010111; // 5C...
    vend_i6n = A[15:14]==1 && ( A[12] || !WOC0 || (!init && A[13]));
    vend_aux =&{ A[9:7], vend_i7n };
    // Simpsons by default:
    banked_cs  =  init && A[15:13]==3 && !Aupper[4]; // 6000~7FFF
    prog_cs    = (init && A[14:13]==3 &&  Aupper[4]) || A[15];
    ram_cs     = A[15:13]==2 && init;
    cr_cs      = io_cs && A[3:1] == 4;
    // after second decoder:
    pal_cs     = A[15:12]==0 && WOC0; // COLOCS in sch
    objsys_cs  = A[15:13]==1 && WOC1 && init;
    eeprom_cs  = io_aux && A[6:4]==3'b000;
    joystk_cs  = io_aux && A[6:4]==3'b001;
    objreg_cs  = io_aux && A[6:4]==3'b010;
    pcu_cs     = io_aux && A[6:4]==3'b011; // 053251
    io_cs      = io_aux && A[6:4]==3'b100;
    tilesys_cs = (~i6n & (~A[9] | ~A[8] | ~A[7] | (A[6]&(A[5]|A[4])))) | (i6n^i7n);

    snd_irq    = io_cs && A[3:1]==2;
    snd_cs     = io_cs && A[3:1]==3;

    rom_cs     = prog_cs | banked_cs;
    rom_addr[16:13] = A[15] ? {2'b11,A[14:13]} : Aupper[3:0];
    rom_addr[17]    = A[15] | Aupper[5];
    rom_addr[18]    = ~banked_cs;
    if( !rom_cs ) rom_addr[15:0] = A[15:0]; // necessary to address gfx chips correctly

    if( paroda ) begin
        cr_cs      = 0;
        joystk_cs  = paro_aux && A[6:4]==3'b000;
        io_cs      = paro_aux && A[6:4]==3'b001;
        objreg_cs  = paro_aux && A[6:4]==3'b010;
        pcu_cs     = paro_aux && A[6:4]==3'b011; // 053251
        tilesys_cs = paro_i7n && (A[8:7]==1 || A[9:8]==1 || !A[7] || paro_i6n );
        snd_irq    = misc_cs  && A[3:2]==2;
        snd_cs     = misc_cs  && A[3:2]==3;
        ram_cs     = A[15:13]==0 && |{A[12:11],~WOC0};
        pal_cs     = A[15:11]==0 && WOC0;
        objsys_cs  = A[15:11]==4 && WOC1;
        banked_cs  = A[15:13]==4 || (A[15:13]==3 && bankr); // 6000~7FFF on bankr, 8000~9FFF always
        rom_cs     = banked_cs || A[15];
        rom_addr[16:13] = banked_cs ? {~Aupper[2:0], A[15]} : {1'b1,A[15:13]};
        rom_addr[17] = !Aupper[3]||!banked_cs;
        rom_addr[18] = 0;
    end
    if( suratk ) begin
        cr_cs      = 0;
        // 053884
        joystk_cs  = suratk_aux && A[6:4]==3'b000;
        io_cs      = suratk_aux && A[6:4]==3'b001;
        objreg_cs  = suratk_aux && A[6:4]==3'b010;
        pcu_cs     = suratk_aux && A[6:4]==3'b011; // 053251
        fm_cs      = suratk_aux && A[6:4]==3'b101;
        tilesys_cs = suratk_i7n && (A[8:7]==1 || A[9:8]==1 || !A[7] || suratk_i6n );
    //     tilesys_cs =
    //    (A[9:7]==3'b000 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b100 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b010 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b110 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b001 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b101 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b011 && !suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b000 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b100 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b010 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b110 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b001 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b101 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b011 &&  suratk_i6n && !suratk_i7n)
    // || (A[9:7]==3'b111 &&  suratk_i6n && !suratk_i7n);
        snd_irq    = 0;
        snd_cs     = 0;
        // 053888
        ram_cs     = A[15:11]==1 || A[15:12]==1 || (A[15:13]==0 && !WOC1 && !WOC0);
        objsys_cs  = A[15:11]==0 && !WOC1 &&  WOC0;
        pal_cs     = A[15:11]==0 &&  WOC1 && !WOC0;
        banked_cs  = A[15:13]==1 && bankr;
        rom_cs     = banked_cs || A[15];
        rom_addr[17:13] = banked_cs ? Aupper[4:0] : {2'b11,A[15:13]};
        rom_addr[18] = 0;
    end
    if( vendetta ) begin
        // PAL U22
        tilesys_cs =(vend_i6n && !vend_i7n) || vend_i7n && (!A[9]||!A[8]||!A[7]);
        hip_cs     = vend_aux && A[6:5]==2'b00;
        io_cs      = vend_aux && A[6:4]==3'b110;
        pcu_cs     = vend_aux && A[6:4]==3'b010;
        objreg_cs  = vend_aux && A[6:4]==3'b011;
        stsw_cs    = vend_aux && A[6:4]==3'b101;
        joystk_cs  = vend_aux && A[6:4]==3'b100;
        // PAL U21
        rom_cs     = A[15] || (A[14:13]==0);
        pal_cs     = A[15:12]==6 && WOC0;
        objsys_cs  = A[15:12]==4 && WOC0;
        ram_cs     = A[15:13]==1;
        // Decoder U25
        snd_cs     = io_cs && A[3:1]==3;
        snd_irq    = io_cs && A[3:1]==2;
        // ROM address
        rom_addr[17:13] = A[15] ? {3'b111,A[14:13]} : Aupper[4:0]; // 2Mbit ROM in PCB. Schematics only show a 1Mbit connection
        rom_addr[18]    = 0;
    end
    if( esckids ) begin
        // GX975 Escape Kids map.  Video-bank views are exclusive with the
        // corresponding K052109 window, matching vendetta.cpp:405-436.
        ram_cs      = A[15:13]==3'b000;
        banked_cs   = !cpu_we && A[15:13]==3'b011;  // ROM reads only; writes access K052109 config
        prog_cs     = !cpu_we && A[15];
        tilesys_cs  = A>=16'h2000 && A<=16'h5fff;
        objsys_cs   = video_bank && A[15:12]==4'h2;
        pal_cs      = video_bank && A[15:12]==4'h4;
        tilesys_cs  = tilesys_cs && !objsys_cs && !pal_cs;
        joystk_cs   = A>=16'h3f80 && A<=16'h3f83;
        eeprom_cs   = A==16'h3f92;
        stsw_cs     = A==16'h3f93;
        objreg_cs   = A>=16'h3fa0 && A<=16'h3fa7;
        pcu_cs      = A[15:4]==12'h3fb;
        k053252_cs  = A[15:4]==12'h3fc;
        snd_irq     = A==16'h3fd4;
        snd_cs      = A>=16'h3fd6 && A<=16'h3fd7;
        objread_cs  = A>=16'h3fd8 && A<=16'h3fd9;
        // The 053327 tile window is broad, but the Escape control writes at
        // 3fd0/3fd2 and the observed 3fda no-op/watchdog candidate are not
        // tile accesses.  Keep them outside the tile chip-select so the
        // decoded overlay is one-hot at the first control transaction.
        tilesys_cs  = tilesys_cs && !(joystk_cs || eeprom_cs || stsw_cs ||
                      objreg_cs || pcu_cs || k053252_cs || snd_irq ||
                      snd_cs || objread_cs || esckids_ctrl0_cs ||
                      esckids_ctrl2_cs || esckids_watchdog_cs);
        // The project board/ROM-trace evidence includes a boot write to
        // 0x7C00. MAME esckids_map maps 0x6000-0x7FFF as banked ROM, so
        // this alias is retained as hardware/ROM-trace evidence, not
        // inferred from the MAME address map alone.
        // Writes only: 0x6000-0x7FFF is the banked program ROM for reads.
        if( cpu_we && A[15:10]==6'b011111 ) tilesys_cs = 1;
        io_cs       = 0;
        cr_cs       = 0;
        out_cs      = 0;
        basel_cs    = 0;
        hip_cs      = 0;
        fm_cs       = 0;
        // Physical program depth is 128 KiB.  Aupper[3:0] is the lower
        // four bank-line bits produced by JTKCPU; higher banks are not
        // synthesized into a generic MAME-sized allocation.
        if( banked_cs )
            rom_addr = { 2'b00, Aupper[3:0], A[12:0] };
        else if( prog_cs )
            rom_addr = { 4'b0011, A[14:0] };
        else
            rom_addr = 0;
        rom_cs = banked_cs | prog_cs;
    end
end

always @* begin
    cpu_din = rom_cs     ? rom_data     : // maximum priority
              ram_cs     ? ram_dout     :
              cab_rd     ? port_in      :
              pal_cs     ? pal_dout     :
              hip_cs     ? hip_dout     : // vendetta only
              tilesys_cs ? tilesys_dout :
              k053252_cs ? k053252_dout :
              objread_cs ? objsys_dout :
              snd_cs     ? snd2main     :
              fm_cs      ? fm_dout      : // suratk only
              (objsys_cs | cr_cs) ? objsys_dout  : 8'h00;
end

`ifdef SIMULATION
// Escape Kids has a physical 128 KiB program ROM.  Keep the bank/fixed
// address contract executable without changing the synthesizable decode.
always @(posedge clk) begin
    if( !rst && esckids && rom_cs ) begin
        if( banked_cs && rom_addr[18:17] != 2'b00 )
            $error("Escape Kids banked ROM escaped 128 KiB: A=%04X upper=%02X rom_addr=%05X", A, Aupper, rom_addr);
        if( prog_cs && rom_addr[18:15] != 4'b0011 )
            $error("Escape Kids fixed ROM lost 0x18000 base: A=%04X rom_addr=%05X", A, rom_addr);
    end
end
`endif

always @(posedge clk) begin
    if( rst ) begin
        port_in   <= 0;
        rmrd      <= 0;
        init      <= 0; // missing this will result in garbled scroll after reset
        berr_l    <= 0;
        WOC0      <= 0;
        WOC1      <= 0;
        // vendetta only:
        irqen     <= 0;
        // simpsons only:
        firqen    <= 0;
        eep_di    <= 0;
        eep_cs    <= 0;
        eep_clk   <= 0;
        mono      <= 0;
        objcha_n  <= 0;
        video_bank<= 0;
        // parodius only:
        pal_bank  <= 0;
        bankr     <= 0;
    end else begin
        if( buserror ) berr_l <= 1;
        if( paroda | suratk ) begin
            objcha_n <= 1;
            //in k053244 actually
            //if(objreg_cs && cpu_addr[3:0] == 5) objcha_n <= !cpu_dout[4];
            if(basel_cs) {pal_bank,WOC1,WOC0} <= cpu_dout[2:0];
            if(out_cs && cpu_we) begin
                {bankr, rmrd } <= cpu_dout[4:3]; // coin counters are 1:0 here, unconnected brightness in bits 7:5
                $display("write to out_cs %X",cpu_dout);
            end
            if(io_cs) port_in <= dipsw[15:8];
            if( joystk_cs ) case( A[1:0] )
                2'd0: port_in <= { joystick1[6:4],joystick1[1:0],joystick1[3:2],cab_1p[0] };
                2'd1: port_in <= { joystick2[6:4],joystick2[1:0],joystick2[3:2],cab_1p[1] };
                2'd2: port_in <= { dipsw[23:20], coin[1:0], dip_test, service };
                2'd3: port_in <= dipsw[7:0];
            endcase
        end else if( esckids ) begin
            if( cpu_we && esckids_ctrl0_cs ) begin
                rmrd     <= cpu_dout[3];
                init     <= cpu_dout[4];
                objcha_n <= ~cpu_dout[5];
            end
            if( cpu_we && esckids_ctrl2_cs ) begin
                video_bank <= cpu_dout[0];
                mono       <= cpu_dout[2];
                eep_cs     <= cpu_dout[3];
                eep_clk    <= cpu_dout[4];
                eep_di     <= cpu_dout[5];
                irqen      <= cpu_dout[6];
            end
`ifdef SIMULATION
            if( cpu_we && esckids_watchdog_cs && $test$plusargs("SMOKE_NOOP_DIAG") )
                $display("Escape Kids write to documented no-op/watchdog candidate: %02X",cpu_dout);
`endif
            if( joystk_cs ) case( A[1:0] )
                2'd0: port_in <= { coin[0], joystick1[6:2],joystick1[0],joystick1[1] };
                2'd1: port_in <= { coin[1], joystick2[6:2],joystick2[0],joystick2[1] };
                2'd2: port_in <= cabinet_2p ? 8'hff : { coin[2], joystick3[6:2],joystick3[0],joystick3[1] };
                2'd3: port_in <= cabinet_2p ? 8'hff : { coin[3], joystick4[6:2],joystick4[0],joystick4[1] };
            endcase
        end else if( vendetta ) begin
            if( io_cs ) case( A[3:1] )
                0: { objcha_n, init, rmrd } <= {~cpu_dout[5], cpu_dout[4:3]}; // bit 2 named but unused, bits 1:0 are coin counters
                1: { irqen, eep_di, eep_clk, eep_cs, mono, WOC1, WOC0 } <= cpu_dout[6:0];
                // 4: CRCS
                // 5: AFR (watchdog)
                default:;
            endcase
            if( joystk_cs ) case( A[1:0] )
                2'd0: port_in <= { coin[0], joystick1[6:2],joystick1[0],joystick1[1] };
                2'd1: port_in <= { coin[1], joystick2[6:2],joystick2[0],joystick2[1] };
                2'd2: port_in <= { coin[2], joystick3[6:2],joystick3[0],joystick3[1] };
                2'd3: port_in <= { coin[3], joystick4[6:2],joystick4[0],joystick4[1] };
            endcase
        end else if( simson ) begin
            if( io_cs ) case( A[3:1] )
                0: { objcha_n, init, rmrd, mono } <= cpu_dout[5:2]; // bits 1:0 are coin counters
                1: { eep_di, eep_clk, eep_cs, firqen, WOC1, WOC0 } <= { cpu_dout[7], cpu_dout[4:0] };
                // 4: CRCS
                // 5: AFR (watchdog)
                default:;
            endcase
            if( joystk_cs ) case( A[1:0] )
                2'd0: port_in <= { cab_1p[0], joystick1[6:0] };
                2'd1: port_in <= { cab_1p[1], joystick2[6:0] };
                2'd2: port_in <= { cab_1p[2], joystick3[6:0] };
                2'd3: port_in <= { cab_1p[3], joystick4[6:0] };
            endcase
        end
        if( esckids ) begin
            // MAME's EEPROM port: DO, READY, service/test, and OBJ busy.
            if( eeprom_cs ) port_in <= { 4'hf, dma_bsy, esckids_service, eep_rdy, eep_do };
            if( stsw_cs ) port_in <= cabinet_2p ?
                { 3'b111, esckids_service, 2'b11, cab_1p[1], cab_1p[0] } :
                { 4'hf, esckids_service, 3'b111 };
        end else begin
            // only simson
            if( eeprom_cs ) port_in <= A[0] ? { WOC1, WOC0, eep_rdy, eep_do,
                                                eep_di, eep_clk, eep_cs, dip_test } // real PCB */
                                            //{ 2'b11, eep_rdy, eep_do, 3'b111, dip_test } // use for MAME comparisons
                                            : { {4{service}}, coin };
            // only vendetta
            if( stsw_cs   ) port_in <= A[0] ? { {4{service}}, cab_1p } : { 4'hf, dma_bsy, dip_test, eep_rdy, eep_do };
        end
    end
end

jt5911 #(.SIMFILE("nvram.bin"),.SYNHEX("default.hex")) u_eeprom(
    .rst        ( rst       ),
    .clk        ( clk       ),
    // chip interface
    .sclk       ( eep_clk   ),         // serial clock
    .sdi        ( eep_di    ),         // serial data in
    .sdo        ( eep_do    ),         // serial data out
    .rdy        ( eep_rdy   ),
    .scs        ( eep_cs    ),         // chip select, active high. Goes low in between instructions
    // Dump access
    .mem_addr   ( nv_addr   ),
    .mem_din    ( nv_din    ),
    .mem_we     ( nv_we     ),
    .mem_dout   ( nv_dout   ),
    // NVRAM contents changed
    .dump_clr   ( 1'b0      ),
    .dump_flag  (           )
);

// Vendetta does not use the interrupt from the tile mapper
jtframe_edge #(.QSET(0)) u_irq (
    .rst    ( rst       ),
    .clk    ( clk       ),
    .edgeof ( ~LVBL     ),
    .clr    ( ~irqen    ),
    .q      ( irqn_ff   )
);

jtframe_edge #(.QSET(0)) u_firq (
    .rst    ( rst       ),
    .clk    ( clk       ),
    .edgeof ( ~dma_bsy  ), // FIRQ triggered at the end of the DMA transfer
    .clr    ( ~firqen   ),
    .q      ( firqn_ff  )
);

/* xverilator tracing_off */
// The donor profiles retain the K052109 eight-frame start-up hold. Escape
// Kids uses the board reset and its external K053252 timing instead.
always @(posedge clk) rst_cmb <= rst
`ifndef SIMULATION
    | (rst8 & ~esckids)
`endif
;
assign irq_mx = ((vendetta|esckids) ? irqn_ff : irq_n) | ~dip_pause;

`ifdef SIMSON
// only used in Vendetta
jtk054000 u_hip(
    .rst    ( rst_cmb   ),
    .clk    ( clk       ),
    .cs     ( hip_cs    ),
    .addr   ( A[4:0]    ),
    .we     ( cpu_we    ),
    .din    ( cpu_dout  ),
    .dout   ( hip_dout  )
);
`else
assign hip_dout = 8'b0;
`endif

jtkcpu u_cpu(
    .rst    ( rst_cmb   ),
    .clk    ( clk       ),
    .cen2   ( cen_ref   ),
    .cen_out( cpu_cen   ),

    .halt   ( berr_l    ),
    .dtack  ( dtack     ),
    .nmi_n  ( 1'b1      ),
    .irq_n  ( irq_mx    ),
    .firq_n ( firqn     ),
    .pcbad  ( pcbad     ),
    .buserror( buserror ),

    // memory bus
    .din    ( cpu_din   ),
    .dout   ( cpu_dout  ),
    .addr   ({Aupper, A}),
    .we     ( cpu_we    )
`ifdef JTKCPU_DEBUG
   ,.x      ( cpu_x      ),
    .y      ( cpu_y      ),
    .u      ( cpu_u      ),
    .s      ( cpu_s      ),
    .pc     ( cpu_pc     ),
    .a      ( cpu_a      ),
    .b      ( cpu_b      ),
    .cc     ( cpu_cc     ),
    .dp     ( cpu_dp     ),
    .is_op  ( cpu_is_op  )
`endif
);
/* verilator tracing_on */
`else
    assign cpu_cen   = 0;
    assign cpu_dout  = 0;
    assign cpu_addr  = 0;
    assign ram_addr  = 0;
    assign ram_we    = 0;
    assign cpu_we    = 0;
    assign pal_we    = 0;
    assign snd_wrn   = 1;
    assign nv_din    = 0;
    assign nv_addr   = 0;
    assign nv_we     = 0;

    initial begin
        init       = 0;
        rom_addr   = 0;
        rom_cs     = 0;
        rmrd       = 0;
        pcu_cs     = 0;
        tilesys_cs = 0;
        objsys_cs  = 0;
        objreg_cs  = 0;
        objcha_n   = 1;
        video_bank = 0;
        k053252_cs = 0;
        snd_irq    = 0;
        mono       = 0;
        pal_bank   = 0;
        st_dout    = 0;
        fm_cs      = 0;
    end
`endif
endmodule
