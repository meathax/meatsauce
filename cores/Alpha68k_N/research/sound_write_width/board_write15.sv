// Alpha68k N CPUs and board bus, one 48 MHz master with enables.
module alpha68kn_board (
    input  logic clk,
    input  logic reset,
    input  logic downloading,
    input  logic load_wr,
    input  logic [24:0] load_addr,
    input  logic [15:0] load_data,
    input  logic [15:0] controls,
    input  logic [7:0] dips,
    input  logic [1:0] coins_n,
    input wire pause_game,hs_access,hs_write,
    input wire [23:0] hs_addr,
    input wire [7:0] hs_data_in,
    output wire [7:0] hs_data_out,
    output reg paused=0,
    output logic [7:0] profile = 0,
    output logic ce_pix,
    output logic [8:0] x,
    output logic [8:0] y,
    output logic hblank, vblank, hs, vs,
    output logic gfx_load_wr,
    output logic [18:0] gfx_load_addr,
    output logic [15:0] gfx_load_data,
    output logic [15:0] background,
    output logic flip,
    output logic [7:0] dac,
    output logic sound_io_wr,
    output logic [7:0] sound_io_addr, sound_io_data,
    output wire sound_io_rd,
    output wire [7:0] sound_io_read_addr,
    input wire [7:0] sound_io_read_data,
    output logic sound_dac_wr,
    output logic [23:0] debug_main_addr,
    output logic [15:0] debug_sound_addr,
    output wire [4:0] debug_sound_attrs,
    output wire [7:0] debug_sound_din,debug_sound_dout,
    output logic debug_main_as_n,
    output wire [3:0] debug_main_attrs,
    output wire [15:0] debug_main_din, debug_main_dout,
    output logic [31:0] main_transactions, sound_transactions,
    output logic [31:0] work_writes, strip_writes, mcu_transactions,
    output logic [31:0] irq1_acks, irq2_acks, unmapped_accesses,
    input  logic [11:0] debug_word_addr,
    output logic [15:0] debug_work_data, debug_strip_data,
    output wire [23:0] background_rgb,
    input logic [3:0] debug_rom_kind,
    input logic [15:0] debug_rom_addr,
    output logic [15:0] debug_rom_data
);
    wire held_reset = reset | downloading;
    always @(posedge clk) paused<=pause_game && !held_reset;
    logic [2:0] phase,cpu_phase;
    logic [3:0] zphase;
    logic [19:0] irq2_count;
    logic [13:0] nmi_count;
    logic [4:0] nmi_width;
    logic irq1, irq2, sound_irq;
    wire [2:0] level = irq2 ? 3'd2 : irq1 ? 3'd1 : 3'd0;
    wire ce_z80 = zphase == 0;
    wire vblank_edge = ce_pix && x == 383 && y == 239;
    assign ce_pix = phase == 0;
    assign hblank = x >= 256;
    assign vblank = y < 16 || y >= 240;
    assign hs = !(x >= 272 && x < 304);
    assign vs = !(y >= 248 && y < 252);

    logic [15:0] main_rom [0:65535];
    logic [15:0] sound_rom [0:32767];
    logic [7:0] work_hi [0:2047],work_lo [0:2047];
    logic [7:0] strip_hi [0:4095],strip_lo [0:4095];
    logic [7:0] renderer_strip_hi [0:4095],renderer_strip_lo [0:4095];
    logic [15:0] work_word22=0;
    logic [7:0] work29_high=0;
    logic [7:0] work_hi_q=0,work_lo_q=0,strip_hi_q=0,strip_lo_q=0;
    logic [15:0] work22_q=0;
    logic work_q_is22=0,hs_read_active=0,hs_read_odd=0;
    logic [7:0] hs_hold=0;
    logic [1:0] response_kind=0;
    wire [15:0] work_q=work_q_is22 ? work22_q : {work_hi_q,work_lo_q};
    wire [15:0] strip_q={strip_hi_q,strip_lo_q};
    wire [7:0] hs_current=hs_read_odd ? work_q[7:0] : work_q[15:8];
    assign hs_data_out=hs_read_active ? hs_current : hs_hold;
    logic [7:0] sound_ram [0:2047];
    logic [7:0] prom_r [0:255], prom_g [0:255], prom_b [0:255];
    logic [7:0] clut_rom [0:511], color_rom [0:8191], mcu_rom [0:4095];
    wire [7:0] bg_index = background[7:0];
    assign background_rgb = {prom_r[bg_index][3:0],prom_r[bg_index][3:0],
        prom_g[bg_index][3:0],prom_g[bg_index][3:0],
        prom_b[bg_index][3:0],prom_b[bg_index][3:0]};
    // Initialized once, not repeatedly cleared while reset is held.
    initial begin
        background=0;
        for (integer i=0;i<2048;i=i+1) begin work_hi[i]=0;work_lo[i]=0;sound_ram[i]=0;end
        for (integer i=0;i<4096;i=i+1) begin strip_hi[i]=0;strip_lo[i]=0;renderer_strip_hi[i]=0;renderer_strip_lo[i]=0;end
    end

    always_ff @(posedge clk) begin
        gfx_load_wr <= 0;
        if (load_wr) begin
            if (load_addr == 4) profile <= load_data[15:8];
            if (load_addr >= 'h00100 && load_addr < 'h20100)
                main_rom[(load_addr-'h00100)>>1] <= {load_data[7:0],load_data[15:8]};
            if (load_addr >= 'h20100 && load_addr < 'h30100)
                sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;
            if (load_addr >= 'h30100 && load_addr < 'h30200) begin
                prom_r[load_addr[7:0]]<=load_data[7:0]; prom_r[load_addr[7:0]+8'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h30200 && load_addr < 'h30300) begin
                prom_g[load_addr[7:0]]<=load_data[7:0]; prom_g[load_addr[7:0]+8'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h30300 && load_addr < 'h30400) begin
                prom_b[load_addr[7:0]]<=load_data[7:0]; prom_b[load_addr[7:0]+8'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h30400 && load_addr < 'h30600) begin
                clut_rom[load_addr[8:0]]<=load_data[7:0]; clut_rom[load_addr[8:0]+9'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h31000 && load_addr < 'h33000) begin
                color_rom[load_addr[12:0]-13'h1000]<=load_data[7:0];
                color_rom[load_addr[12:0]-13'h1000+13'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h33000 && load_addr < 'h34000) begin
                mcu_rom[load_addr[11:0]]<=load_data[7:0]; mcu_rom[load_addr[11:0]+12'd1]<=load_data[15:8];
            end
            if (load_addr >= 'h40000 && load_addr < 'ha0000) begin
                gfx_load_wr <= 1;
                gfx_load_addr <= 19'(load_addr-'h40000);
                gfx_load_data <= load_data;
            end
        end
        // Unconsumed physical work diagnostic output; simulation observation only.
`ifdef VERILATOR
        debug_work_data <= debug_word_addr[10:0]==11'h22 ? work_word22 :
            {work_hi[debug_word_addr[10:0]],work_lo[debug_word_addr[10:0]]};
`else
        debug_work_data <= 16'd0;
`endif
        // This is the physical renderer read port: preserve cross-port OLD_DATA.
        debug_strip_data <= {renderer_strip_hi[debug_word_addr],renderer_strip_lo[debug_word_addr]};
        case (debug_rom_kind)
            1:debug_rom_data<=main_rom[debug_rom_addr];
            2:debug_rom_data<={sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};
            3:debug_rom_data<={prom_r[debug_rom_addr[7:0]],prom_r[debug_rom_addr[7:0]+8'd1]};
            4:debug_rom_data<={prom_g[debug_rom_addr[7:0]],prom_g[debug_rom_addr[7:0]+8'd1]};
            5:debug_rom_data<={prom_b[debug_rom_addr[7:0]],prom_b[debug_rom_addr[7:0]+8'd1]};
            6:debug_rom_data<={clut_rom[debug_rom_addr[8:0]],clut_rom[debug_rom_addr[8:0]+9'd1]};
            7:debug_rom_data<={color_rom[debug_rom_addr[12:0]],color_rom[debug_rom_addr[12:0]+13'd1]};
            8:debug_rom_data<={mcu_rom[debug_rom_addr[11:0]],mcu_rom[debug_rom_addr[11:0]+12'd1]};
            default:debug_rom_data<=16'hffff;
        endcase
    end

    logic [23:1] ma;
    // A dedicated synchronous ROM read port permits M10K inference.
    // Qualify the response with its registered address before asserting DTACK.
    logic [15:0] main_rom_q,main_rom_addr_q;
    always_ff @(posedge clk) begin
        main_rom_q<=main_rom[ma[16:1]];
        main_rom_addr_q<=ma[16:1];
    end

    logic [15:0] mdout, mdin_other;
    wire [15:0] mdin=response_kind==1 ? work_q :
                        response_kind==2 ? strip_q : mdin_other;
    logic mas_n, mrw_n, muds_n, mlds_n;
    logic fc0,fc1,fc2;
    logic bus_done;
    wire iack = !mas_n && fc0 && fc1 && fc2;
    wire [23:0] maddr = {ma,1'b0};
    assign debug_main_addr = maddr;
    assign debug_main_as_n = mas_n;
    assign debug_main_attrs = {iack,mrw_n,muds_n,mlds_n};
    assign debug_main_din = mdin;
    assign debug_main_dout = mdout;
    fx68k maincpu (
        .clk(clk), .HALTn(1'b1), .extReset(held_reset), .pwrUp(held_reset),
        .enPhi1(cpu_phase==0 && !pause_game), .enPhi2(cpu_phase==4 && !pause_game),
        .eRWn(mrw_n), .ASn(mas_n), .LDSn(mlds_n), .UDSn(muds_n),
        .E(), .VMAn(), .FC0(fc0), .FC1(fc1), .FC2(fc2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(!(bus_done && !iack)), .VPAn(!iack), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(!level[0]), .IPL1n(!level[1]), .IPL2n(!level[2]),
        .iEdb(mdin), .oEdb(mdout), .eab(ma)
    );

    logic [15:0] za;
    logic [7:0] zdout, zdin;
    logic zm1_n, zmreq_n, ziorq_n, zrd_n, zwr_n;
    logic zbus_done;
    logic [7:0] sound_latch;
    logic sound_latch_pending;
    assign debug_sound_addr = za;
    assign debug_sound_attrs = {zm1_n,zmreq_n,ziorq_n,zrd_n,zwr_n};
    assign debug_sound_din = zdin;
    assign debug_sound_dout = zdout;
    assign sound_io_rd = !held_reset && !pause_game && !ziorq_n && !zrd_n;
    assign sound_io_read_addr = za[7:0];
    T80s soundcpu (
        .RESET_n(!held_reset), .CLK(clk), .CEN(ce_z80 && !pause_game), .WAIT_n(1'b1),
        .INT_n(!sound_irq), .NMI_n(nmi_width==0), .BUSRQ_n(1'b1), .OUT0(1'b0),
        .DI(zdin), .M1_n(zm1_n), .MREQ_n(zmreq_n), .IORQ_n(ziorq_n),
        .RD_n(zrd_n), .WR_n(zwr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(),
        .A(za), .DOUT(zdout)
    );
    // Parallel word/control captures preserve the original post-edge DI value.
    logic [15:0] sound_rom_q;
    logic sound_rom_lane_q, sound_rom_selected_q;
    logic [7:0] sound_nonrom_q;
    always_ff @(posedge clk) begin
        sound_rom_q <= sound_rom[za[15:1]];
        sound_rom_lane_q <= za[0];
        sound_rom_selected_q <= !sound_io_rd && za < 'hc000;
        if (sound_io_rd) sound_nonrom_q <= sound_io_read_data;
        else if (za >= 'hc000 && za < 'hc800) sound_nonrom_q <= sound_ram[za[10:0]];
        else if (za == 'he000) sound_nonrom_q <= sound_latch;
        else sound_nonrom_q <= 8'hff;
    end
    assign zdin = sound_rom_selected_q ?
        (sound_rom_lane_q ? sound_rom_q[15:8] : sound_rom_q[7:0]) : sound_nonrom_q;

    logic coin_latch;
    logic [3:0] deposits_a, deposits_b;
    logic [7:0] credits;
    wire [2:0] coinage = (~dips >> 1) & 7;
    function automatic [3:0] required_coins(input bit slot_b,input logic [2:0] setting);
        if (slot_b) case(setting)
            0:required_coins=1;1:required_coins=5;2:required_coins=3;3:required_coins=7;
            4:required_coins=2;5:required_coins=6;6:required_coins=4;7:required_coins=8;
        endcase
        else case(setting)
            3:required_coins=2;7:required_coins=3;default:required_coins=1;
        endcase
    endfunction
    function automatic [7:0] award_credits(input bit slot_b,input logic [2:0] setting);
        if (slot_b) award_credits = setting==3 || setting==7 ? 2 : 1;
        else case(setting)
            0:award_credits=1;1:award_credits=5;2:award_credits=3;3:award_credits=3;
            4:award_credits=2;5:award_credits=6;6:award_credits=4;7:award_credits=2;
        endcase
    endfunction

    // Exact accepted edge; no CPU enable, AS, byte-strobe or DTACK change.
    wire ram_bus_service=!held_reset && !pause_game && !mas_n && !bus_done
        && (iack || !muds_n || !mlds_n)
        && (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1]);
    wire cpu_work_service=ram_bus_service && !iack && maddr>=24'h020000 && maddr<24'h021000;
    wire cpu_strip_service=ram_bus_service && !iack && maddr>=24'h040000 && maddr<24'h042000;
    wire hs_work_service=!held_reset && pause_game && paused && hs_access
        && hs_addr>=24'h020000 && hs_addr<24'h021000;
    wire hle_service=ram_bus_service && !iack && mrw_n && maddr>=24'h080000 && maddr<24'h080200;
    wire hle_coin=hle_service && ma[8:1]==8'h29 && !coin_latch && coins_n!=2'b11;
    wire hle_low_write=hle_service && (ma[8:1]==8'h22 || ma[8:1]==8'hff || ma[8:1]==8'h29);
    wire [10:0] work_port_addr=hs_work_service ? hs_addr[11:1] :
                             cpu_work_service ? ma[11:1] : {3'd0,ma[8:1]};
    wire work_write_hi=(hs_work_service && hs_write && !hs_addr[0])
                      || (cpu_work_service && !mrw_n && !muds_n);
    wire work_write_lo=(hs_work_service && hs_write && hs_addr[0])
                      || (cpu_work_service && !mrw_n && !mlds_n) || hle_low_write;
    wire [7:0] work_data_hi=hs_work_service ? hs_data_in : mdout[15:8];
    wire [7:0] work_data_lo=hs_work_service ? hs_data_in : cpu_work_service ? mdout[7:0] :
                  ma[8:1]==8'h22 ? credits : ma[8:1]==8'hff ? 8'h12 : hle_coin ? 8'h22 : 8'h00;
    // Write-only full-byte banks plus one selected synchronous read port.
    // The cross-port old-data contract includes hiscore write/read and CPU DI.
    always @(posedge clk) begin
        if(work_port_addr!=11'h22) begin
            if(work_write_hi) work_hi[work_port_addr]<=work_data_hi;
            if(work_write_lo) work_lo[work_port_addr]<=work_data_lo;
        end
        if(cpu_work_service || hs_work_service) begin
            work_hi_q<=work_hi[work_port_addr];
            work_lo_q<=work_lo[work_port_addr];
            work22_q<=work_word22;
            work_q_is22<=work_port_addr==11'h22;
        end
        if(hs_read_active && !hs_work_service) hs_hold<=hs_current;
        hs_read_active<=hs_work_service;
        if(hs_work_service) hs_read_odd<=hs_addr[0];
        if(work_write_hi && work_port_addr==11'h29) work29_high<=work_data_hi;
        // Word0x22 is a tiny external register. Coin writes it simultaneously
        // with low0x29; RHS shadow is the original pre-edge high0x29.
        if(work_port_addr==11'h22) begin
            if(work_write_hi) work_word22[15:8]<=work_data_hi;
            if(work_write_lo) work_word22[7:0]<=work_data_lo;
        end
        if(hle_coin) work_word22<={work29_high,8'd0};
    end
    // Two SDP copies avoid unsupported true-dual-port inference. Every byte
    // write updates both copies; CPU and physical renderer read OLD_DATA.
    // Extra65536bits remain subject to the complete fitted resource gates.
    always @(posedge clk) begin
        if(cpu_strip_service) begin
            strip_hi_q<=strip_hi[ma[12:1]];
            strip_lo_q<=strip_lo[ma[12:1]];
        end
        if(cpu_strip_service && !mrw_n) begin
            if(!muds_n) begin
                strip_hi[ma[12:1]]<=mdout[15:8];
                renderer_strip_hi[ma[12:1]]<=mdout[15:8];
            end
            if(!mlds_n) begin
                strip_lo[ma[12:1]]<=mdout[7:0];
                renderer_strip_lo[ma[12:1]]<=mdout[7:0];
            end
        end
    end

    always_ff @(posedge clk) begin
        sound_io_wr <= 0;
        sound_dac_wr <= 0;
        if (held_reset) begin
            // MAME raw-screen epoch begins at vblank (240,0). Starting at
            // line zero changes the first field length and startup IRQ phase.
            phase<=0;cpu_phase<=0;zphase<=0;x<=0;y<=240;irq2_count<=0;nmi_count<=0;nmi_width<=0;
            irq1<=0;irq2<=0;sound_irq<=0;bus_done<=0;zbus_done<=0;
            // MAME maps this word as retained RAM (watchdog/BGC), not a
            // reset-cleared video register. A new ROM download starts clean.
            if(downloading) background<=0;
            flip<=0;dac<=0;mdin_other<=16'hffff;response_kind<=0;
            coin_latch<=0;deposits_a<=0;deposits_b<=0;credits<=0;
            sound_latch<=0;sound_latch_pending<=0;
            main_transactions<=0;sound_transactions<=0;work_writes<=0;strip_writes<=0;
            mcu_transactions<=0;irq1_acks<=0;irq2_acks<=0;unmapped_accesses<=0;
        end else begin
            phase <= phase+1'b1;
            if(!pause_game) cpu_phase<=cpu_phase+1'b1;
            if(!pause_game) zphase <= zphase==11 ? 0 : zphase+1'b1;
            if (ce_pix) begin
                if (x==383) begin x<=0;y<=y==263 ? 0 : y+1'b1; end
                else x<=x+1'b1;
            end
            if (!pause_game) begin
            if (vblank_edge) begin irq1<=1;sound_irq<=1; end
            if (irq2_count==799999) begin irq2_count<=0;irq2<=1; end
            else irq2_count<=irq2_count+1'b1;
            if (nmi_width!=0) nmi_width<=nmi_width-1'b1;
            if (nmi_count==11999) begin nmi_count<=0;nmi_width<=24; end
            else nmi_count<=nmi_count+1'b1;
            if (!ziorq_n && !zm1_n) sound_irq<=0;
            end
            // Borrow the work RAM only after the CPUs/bus writers acknowledge
            // pause. 68000 memory is big endian: even byte selects D15:8.
            // Snapshot last CPU response before paused-HS reuses the RAM read.
            // Legacy mdin holds during pause and after resume until next service.
            if(pause_game && !paused) begin mdin_other<=mdin;response_kind<=0;end
            if(!pause_game) begin

            if (mas_n) bus_done<=0;
            // fx68k asserts AS before write byte strobes. Never acknowledge or
            // commit that address-only phase; stack/data writes would be lost.
            else if (!bus_done && (iack || !muds_n || !mlds_n)
                && (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1])) begin
                bus_done<=1;
                main_transactions<=main_transactions+1'b1;
                mdin_other<=16'hffff;response_kind<=0;
                if (iack) begin
                    if (maddr[3:1]==2) begin irq2<=0;irq2_acks<=irq2_acks+1'b1; end
                    else if (maddr[3:1]==1) begin irq1<=0;irq1_acks<=irq1_acks+1'b1; end
                end else if (maddr < 'h020000) mdin_other<=main_rom_q;
                else if (maddr >= 'h020000 && maddr < 'h021000) begin
                    response_kind<=1;
                    if(!mrw_n) work_writes<=work_writes+1'b1;
                end else if (maddr >= 'h040000 && maddr < 'h042000) begin
                    response_kind<=2;
                    if(!mrw_n) strip_writes<=strip_writes+1'b1;
                end else if (maddr=='h060000) begin
                    mdin_other<=background;
                    if (!mrw_n) begin
                        if (!muds_n) background[15:8]<=mdout[15:8];
                        if (!mlds_n) background[7:0]<=mdout[7:0];
                    end
                end else if (maddr >= 'h080000 && maddr < 'h080200) begin
                    mdin_other<=0;mcu_transactions<=mcu_transactions+1'b1;
                    if (!mrw_n) begin
                        if (ma[8:1]=='h2d && !mlds_n) flip<=mdout[0];
                    end else case(ma[8:1])
                        'h22:begin end // full-byte storage service above
                        'hff:begin end // full-byte storage service above
                        'h29:begin
                            if (coins_n==3) coin_latch<=0;
                            if (!coin_latch && !coins_n[0]) begin
                                coin_latch<=1;
                                if (deposits_a+1'b1==required_coins(0,coinage)) begin
                                    credits<=award_credits(0,coinage);deposits_a<=0;
                                end else begin deposits_a<=deposits_a+1'b1;credits<=0; end
                            end else if (!coin_latch && !coins_n[1]) begin
                                coin_latch<=1;
                                if (deposits_b+1'b1==required_coins(1,coinage)) begin
                                    credits<=award_credits(1,coinage);deposits_b<=0;
                                end else begin deposits_b<=deposits_b+1'b1;credits<=0; end
                            end
                        end
                        default:unmapped_accesses<=unmapped_accesses+1'b1;
                    endcase
                end else if (maddr=='h0c0000) mdin_other<=controls;
                else if (maddr=='h0e0000) begin
                    mdin_other<={dips,8'hff};
                    if (!mrw_n && !muds_n) begin sound_latch<=mdout[15:8];sound_latch_pending<=1; end
                end else unmapped_accesses<=unmapped_accesses+1'b1;
            end

            if (zrd_n && zwr_n) zbus_done<=0;
            else if (!zbus_done) begin
                zbus_done<=1;sound_transactions<=sound_transactions+1'b1;
                if (!zwr_n && !zmreq_n) begin
                    if (za >= 'hc000 && za < 'hc800) sound_ram[za[10:0]]<=zdout;
                    if (za=='he002) begin sound_latch<=0;sound_latch_pending<=0; end
                    if (za=='he004) begin dac<=zdout;sound_dac_wr<=1; end
                end
                if (!zwr_n && !ziorq_n) begin
                    sound_io_wr<=1;sound_io_addr<=za[7:0];sound_io_data<=zdout;
                end
            end
            end
        end
    end
endmodule
