import s24_pkg::*;

module s24_core #(
    parameter int unsigned CLK_HZ = 48_000_000,
    parameter bit A_OPCACHE_ENABLE = 1'b1
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    // Average the two fields of a frame-rate tilemap blink instead of showing
    // them alternately (see s24_tile.sv). Off reproduces the raw 28.75 Hz
    // alternation the PCB emits, which is what the MAME pixel-exact
    // comparisons expect; on reproduces what its CRT integrated. The user
    // menu toggle is further gated per board below (blend_capable) -- see
    // that signal's comment for why.
    input  logic        flicker_blend,
    input  board_desc_t board,
    input  logic        key_wr,
    input  logic [11:0] key_word_addr,
    input  logic [15:0] key_wdata,
    input  logic [63:0] input_ports,
    input  logic [8:0]  spinner0,
    input  logic [8:0]  spinner1,
    input  logic [8:0]  spinner2,
    input  logic [8:0]  spinner3,
    input  logic [7:0]  paddle0,
    input  logic [7:0]  paddle1,
    input  logic [7:0]  paddle2,
    input  logic [7:0]  paddle3,

    output logic [2:0]  mahjong_line,

    output logic        ce_pixel,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic        video_flip,
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue,
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,
    // One clk pulse after an emulated floppy byte has reached SDRAM.  The
    // MiSTer wrapper uses this to debounce host-side persistent-media saves.
    output logic        floppy_written,
    output logic        p0_req,
    output logic [26:1] p0_addr,
    input  logic [15:0] p0_data,
    input  logic        p0_ack,
    output logic        p2_req,
    output logic [26:4] p2_addr,
    input  logic [127:0] p2_data,
    input  logic        p2_ack,
    output logic        p3_req,
    output logic [26:1] p3_addr,
    input  logic [15:0] p3_data,
    input  logic        p3_ack,
    output logic        p4_req,
    output logic [26:1] p4_addr,
    input  logic [15:0] p4_data,
    input  logic        p4_ack,
    output logic        wr_req,
    output logic [26:1] wr_addr,
    output logic [15:0] wr_data,
    output logic [1:0]  wr_be,
    input  logic        wr_ack
);
    logic phi1, phi2, ce16, ce8, ce4;
    s24_clock_enables #(.CLK_HZ(CLK_HZ)) clocks(
        .clk(clk),.reset(reset),.pause(pause),.phi1(phi1),.phi2(phi2),
        .ce_16m(ce16),.ce_8m(ce8),.ce_4m(ce4));
    assign ce_pixel = ce16;

    logic [9:0] hcount, vcount;
    logic hsync_tick;
    // Same-cycle 655->0 raster boundary for consumers whose sequential logic
    // must observe the pre-increment vcount.
    logic line_wrap;
    assign line_wrap = ce16 && (hcount == 10'd655);
    s24_video_timing timing(
        .clk(clk),.reset(reset),.ce_pixel(ce16),.hcount(hcount),.vcount(vcount),
        .sync_mode(tile_syncmode[0]),
        .hblank(hblank),.vblank(vblank),.hsync(hsync),.vsync(vsync),
        .hsync_tick(hsync_tick));

    // ------------------------------- CPUs ---------------------------------
    logic a_rw_n,a_as_n,a_lds_n,a_uds_n,b_rw_n,b_as_n,b_lds_n,b_uds_n;
    logic a_dtack_n,b_dtack_n;
    logic a_halted_n;
    logic [2:0] a_fc,b_fc,a_ipl_n,b_ipl_n;
    logic [15:0] a_din,a_dout,b_din,b_dout;
    logic [23:1] a_word_addr,b_word_addr;
    logic b_instr_start;
    logic [15:0] b_instr_opcode;
    logic [23:1] b_instr_address;
    logic a_instr_start;
    logic [15:0] a_instr_opcode;
    logic [23:1] a_instr_address;
    logic [2:0] io_cnt;
    logic io_cnt1_d;
    logic [3:0] sub_reset_count;
    logic sub_reset;
    logic b_phi1,b_phi2;
    logic [26:0] gground_slow_count;
    logic [3:0] gground_pair_index;
    logic gground_pair_enable;
    logic gground_slow;

    // On real System 24/MAME, raising 315-5296 CNT1 releases CPU B from HALT
    // and pulses its RESET input. Preserve state on later CNT1-low halts, but
    // provide a bounded reset pulse on every low-to-high transition.
    assign sub_reset = reset | (io_cnt[1] && !io_cnt1_d) |
                       (sub_reset_count != 0);
    assign gground_slow = (gground_slow_count != 0);

    // Gain Ground measures the shared timer immediately after CPU B is
    // released. MAME models the otherwise-unrepresented bus contention by
    // scaling CPU B to 0.7 for two seconds. Keep complete phi1/phi2 pairs and
    // pass seven of every ten pairs so fx68k sees the same temporary rate.
    assign b_phi1 = phi1 && (!gground_slow || (gground_pair_index < 4'd7));
    assign b_phi2 = phi2 && (!gground_slow || gground_pair_enable);
    always_ff @(posedge clk) begin
        if(reset) begin
            io_cnt1_d<=0;
            sub_reset_count<=0;
            gground_slow_count<=0;
            gground_pair_index<=0;
            gground_pair_enable<=1'b1;
        end else begin
            io_cnt1_d<=io_cnt[1];
            if(io_cnt[1] && !io_cnt1_d) sub_reset_count<=4'd8;
            else if(sub_reset_count!=0) sub_reset_count<=sub_reset_count-1'b1;

            if(io_cnt[1] && !io_cnt1_d &&
               board.input_profile==INPUT_GGROUND) begin
                // clk is 48 MHz: 96,000,000 clocks is exactly two seconds.
                gground_slow_count<=27'd96000000;
                gground_pair_index<=0;
                gground_pair_enable<=1'b1;
            end else begin
                if(!pause && gground_slow_count!=0)
                    gground_slow_count<=gground_slow_count-1'b1;
                if(phi1) begin
                    gground_pair_enable<=!gground_slow ||
                                         (gground_pair_index < 4'd7);
                    if(gground_slow)
                        gground_pair_index<=(gground_pair_index==4'd9) ?
                                             4'd0 : gground_pair_index+1'b1;
                    else
                        gground_pair_index<=0;
                end
            end
        end
    end

    // VPA is only valid during an active CPU-space bus cycle.  Qualifying
    // FC=111 with AS prevents the autovector acknowledge input from being
    // asserted while the CPU is between bus cycles.
    wire a_vpa_n = ~&{a_fc[2],a_fc[1],a_fc[0],~a_as_n};
    wire b_vpa_n = ~&{b_fc[2],b_fc[1],b_fc[0],~b_as_n};

    fx68k cpu_a(
        .clk(clk),.HALTn(1'b1),.extReset(reset),.pwrUp(reset),
        .enPhi1(phi1),.enPhi2(phi2),.eRWn(a_rw_n),.ASn(a_as_n),
        .LDSn(a_lds_n),.UDSn(a_uds_n),.E(),.VMAn(),
        .FC0(a_fc[0]),.FC1(a_fc[1]),.FC2(a_fc[2]),.BGn(),.oRESETn(),.oHALTEDn(a_halted_n),
        .DTACKn(a_dtack_n),.VPAn(a_vpa_n),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(a_ipl_n[0]),.IPL1n(a_ipl_n[1]),.IPL2n(a_ipl_n[2]),
        .iEdb(a_din),.oEdb(a_dout),.eab(a_word_addr),
        .instr_start(a_instr_start),.instr_opcode(a_instr_opcode),
        .instr_address(a_instr_address));
    fx68k cpu_b(
        .clk(clk),.HALTn(io_cnt[1]),.extReset(sub_reset),.pwrUp(reset),
        .enPhi1(b_phi1),.enPhi2(b_phi2),.eRWn(b_rw_n),.ASn(b_as_n),
        .LDSn(b_lds_n),.UDSn(b_uds_n),.E(),.VMAn(),
        .FC0(b_fc[0]),.FC1(b_fc[1]),.FC2(b_fc[2]),.BGn(),.oRESETn(),.oHALTEDn(),
        .DTACKn(b_dtack_n),.VPAn(b_vpa_n),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(b_ipl_n[0]),.IPL1n(b_ipl_n[1]),.IPL2n(b_ipl_n[2]),
        .iEdb(b_din),.oEdb(b_dout),.eab(b_word_addr),
        .instr_start(b_instr_start),.instr_opcode(b_instr_opcode),
        .instr_address(b_instr_address));

    logic bus_req,bus_cpu,bus_rnw,bus_ack;
    logic [1:0] bus_be;
    logic [2:0] bus_fc;
    logic [23:0] bus_addr;
    logic [15:0] bus_dout,bus_din;
    logic a_mem_req,b_mem_req,a_mem_ack,b_mem_ack;
    logic [2:0] a_mem_fc,b_mem_fc;
    logic [23:0] a_mem_addr,b_mem_addr;
    logic [15:0] a_mem_din,b_mem_din;
    s24_cpu_bus cpu_bus(
        .clk(clk),.reset(reset),.cpu_phi1(phi1),.a_halted_n(a_halted_n),
        .a_as_n(a_as_n),.a_rw_n(a_rw_n),.a_uds_n(a_uds_n),.a_lds_n(a_lds_n),
        .a_fc(a_fc),.a_addr(a_word_addr),.a_dout(a_dout),.a_din(a_din),.a_dtack_n(a_dtack_n),
        .b_as_n(b_as_n),.b_rw_n(b_rw_n),.b_uds_n(b_uds_n),.b_lds_n(b_lds_n),
        .b_fc(b_fc),.b_addr(b_word_addr),.b_dout(b_dout),.b_din(b_din),.b_dtack_n(b_dtack_n),
        .bus_req(bus_req),.bus_cpu(bus_cpu),.bus_rnw(bus_rnw),.bus_be(bus_be),
        .bus_fc(bus_fc),.bus_addr(bus_addr),.bus_dout(bus_dout),
        .bus_din(bus_din),.bus_ack(bus_ack),.has_romboard(board.has_romboard),
        .a_mem_req(a_mem_req),.a_mem_fc(a_mem_fc),.a_mem_addr(a_mem_addr),
        .a_mem_din(a_mem_din),.a_mem_ack(a_mem_ack),
        .b_mem_req(b_mem_req),.b_mem_fc(b_mem_fc),.b_mem_addr(b_mem_addr),
        .b_mem_din(b_mem_din),.b_mem_ack(b_mem_ack));

    logic fd_start,fd_key_start,fd_busy,fd_done,fd_irq_enter,b_iack_seen;
    logic [15:0] fd_ciphertext,fd_plaintext;
    logic [7:0] fd_state;
    logic [7:0]  fd_state_used;
    logic        bc_hit_record;
    logic        ac_window,ac_q_valid,ac_hit,ac_fill;
    logic [15:0] ac_hit_data;
    logic        bc_window,bc_q_valid,bc_hit;
    logic [15:0] bc_hit_data;
    logic        bc_fill,bc_snoop;
    logic [26:0] cpu_phys;
    s24_fd1094 fd1094(
        .clk(clk),.reset(sub_reset),.key_wr(key_wr),.key_word_addr(key_word_addr),
        .key_wdata(key_wdata),.start(fd_start),.key_start(fd_key_start),
        .word_address(b_mem_addr[23:1]),
        .encrypted(fd_ciphertext),.irq_enter(fd_irq_enter),.busy(fd_busy),
        .instruction_start(b_instr_start),.instruction_opcode(b_instr_opcode),
        .instruction_address(b_instr_address),
        .done(fd_done),.plaintext(fd_plaintext),.current_state(fd_state),
        .state_used(fd_state_used),
        .hit_record(bc_hit_record),.hit_address(b_mem_addr[23:1]),
        .hit_data(b_mem_din));

    // CPU-B decrypted-opcode cache.  See rtl/cpu/s24_b_opcache.sv for the
    // full rationale (measured 40-50%-of-frame CPU-B memory stalls on
    // hardware).  Lookup window matches the FD1094 decrypt qualification
    // exactly, minus the vector words; non-FD1094 boards cache raw fetches
    // under a constant zero state tag.
    assign bc_window = b_mem_fc[1] && b_mem_addr<24'h100000 &&
                       b_mem_addr[23:1]>23'd3;
    s24_b_opcache bcache(
        // A CNT1 release pulses CPU-B/FD1094 reset. Flush plaintext cache
        // lines on that same reset so a retry cannot execute words decrypted
        // under the previous protected-CPU run.
        .clk(clk),.reset(sub_reset),
        .address(b_mem_addr[23:1]),.fetch_window(bc_window),
        .state_now(board.has_fd1094 ? fd_state : 8'd0),
        .lookup_q_valid(bc_q_valid),.hit(bc_hit),.hit_data(bc_hit_data),
        .fill(bc_fill),.fill_address(b_mem_addr[23:1]),
        .fill_state(board.has_fd1094 ? fd_state_used : 8'd0),
        .fill_data(b_mem_din),
        .snoop(bc_snoop),.snoop_phys(cpu_phys));

    // CPU-A has the same artificial SDRAM fetch latency as CPU-B, without
    // the FD1094 state dimension. Cache repeated program reads while leaving
    // all data reads on the authentic memory path. The reset vectors stay
    // uncached so reset sequencing remains directly observable.
    assign ac_window = a_mem_fc[1] && a_mem_addr<24'h100000 &&
                       a_mem_addr[23:1]>23'd3;
    s24_a_opcache acache(
        .clk(clk),.reset(reset),
        .address(a_mem_addr[23:1]),.fetch_window(ac_window),
        .lookup_q_valid(ac_q_valid),.hit(ac_hit),.hit_data(ac_hit_data),
        .fill(ac_fill),.fill_address(a_mem_addr[23:1]),
        .fill_data(a_mem_din),.snoop(bc_snoop),.snoop_phys(cpu_phys));

    always_ff @(posedge clk) begin
        fd_irq_enter<=1'b0;
        if(reset) b_iack_seen<=1'b0;
        else begin
            if(b_as_n) b_iack_seen<=1'b0;
            else if(!b_iack_seen && b_fc==3'b111) begin
                b_iack_seen<=1'b1;
                fd_irq_enter<=board.has_fd1094;
            end
        end
    end

    // ------------------------------ devices -------------------------------
    logic io_rd,io_wr;
    logic [7:0] io_dout;
    logic [63:0] io_port_out;
    logic [63:0] io_port_write_data;
    logic [7:0] io_dir,io_port_write;
    logic io_cnt2_clock,io_ckot_clock;
    s24_io_5296 io(
        .clk(clk),.reset(reset),.ce_16m(ce16),.rd(io_rd),.wr(io_wr),
        .addr({1'b0,bus_addr[5:1]}),
        .din(bus_dout[7:0]),.dout(io_dout),.port_in(input_ports),
        .port_out(io_port_out),.port_dir(io_dir),
        .port_write(io_port_write),.port_write_data(io_port_write_data),
        .cnt(io_cnt),.cnt2_clock(io_cnt2_clock),.ckot_clock(io_ckot_clock));
    s24_mahjong_mux mahjong_mux(
        .clk(clk),.reset(reset),
        .enable(board.input_profile==INPUT_MAHJONG),
        .port_d_write(io_port_write[3]),
        .port_d_data(io_port_write_data[31:24]),.line(mahjong_line));

    // Optional 834-6510 daughterboard. Hot Rod uses both encoder counters,
    // but only the first ADC (adc0, IC5/"adc1" in MAME, mapped at 0xc00011)
    // is wired to PEDAL1-4. The second ADC chip ("adc2" in MAME, 0xc00013,
    // schematic label "BLAKE") is populated but genuinely unconnected on
    // real hardware -- MAME's driver notes this explicitly and never assigns
    // it an input tag, so adc1 below is correctly tied to idle (8'hff), not
    // dead-wired by omission. Golf cabinets use the first counter when the
    // descriptor says the analog angle control is fitted.
    logic [7:0] upd0_dout,upd1_dout,adc0_dout,adc1_dout;
    logic upd0_read,upd1_read;
    logic upd_read_pending,upd_read_select;
    logic adc0_select,adc1_select,adc0_shift,adc1_shift;
    logic [7:0] pedal0,pedal1,pedal2,pedal3;
    assign pedal0=(paddle0==0)?8'h01:paddle0;
    assign pedal1=(paddle1==0)?8'h01:paddle1;
    assign pedal2=(paddle2==0)?8'h01:paddle2;
    assign pedal3=(paddle3==0)?8'h01:paddle3;
    s24_upd4701 upd0(
        .clk(clk),.reset(reset),.spinner_x(spinner0),.spinner_y(spinner1),
        .addr(bus_addr[2:1]),.read(upd0_read),.dout(upd0_dout));
    s24_upd4701 upd1(
        .clk(clk),.reset(reset),.spinner_x(spinner2),.spinner_y(spinner3),
        .addr(bus_addr[2:1]),.read(upd1_read),.dout(upd1_dout));
    s24_msm6253 adc0(
        .clk(clk),.reset(reset),.select(adc0_select),.shift(adc0_shift),
        .din(bus_dout[7:0]),.an0(pedal0),.an1(pedal1),
        .an2(pedal2),.an3(pedal3),.dout(adc0_dout));
    s24_msm6253 adc1(
        .clk(clk),.reset(reset),.select(adc1_select),.shift(adc1_shift),
        .din(bus_dout[7:0]),.an0(8'hff),.an1(8'hff),
        .an2(8'hff),.an3(8'hff),.dout(adc1_dout));

    logic ym_write_pending, ym_write_accepted, ym_addr_q;
    logic [7:0] ym_data_q;
    logic [7:0] ym_dout;
    logic ym_irq_n,ym_irq_q;
    logic signed [15:0] ym_l,ym_r;
    logic ym_sample_l,ym_sample_r;
    s24_opm ym(
        .clk(clk),.reset(reset),.ce_4m(ce4),
        // CNT2 is wired to the physical YM2151 active-low /IC pin. System 24
        // writes CNT=04 to release the chip.
        .chip_reset_n(io_cnt[2] & ~reset),
        .write_valid(ym_write_pending),.write_a0(ym_addr_q),
        .write_data(ym_data_q),.write_accepted(ym_write_accepted),
        .status(ym_dout),.irq_n(ym_irq_n),
        .sample_strobe_l(ym_sample_l),.sample_strobe_r(ym_sample_r),
        .audio_l(ym_l),.audio_r(ym_r));

    logic irq_rd_a,irq_rd_b,irq_wr;
    logic irq_read_pending;
    logic [15:0] irq_dout;
    logic frc_tick;
    logic frc_int3_n;
    logic frc_mode;
    logic frc_mode_write,frc_ack_write;
    s24_irq irq(
        .clk(clk),.reset(reset),.ce_8m(ce8),.hsync_tick(line_wrap),.vcount(vcount),
        .ym_irq(~ym_irq_n),.int3_n(frc_int3_n),.frc_tick(frc_tick),.frc_mode(frc_mode),
        .frc_ack(frc_ack_write),.rd_a(irq_rd_a),.rd_b(irq_rd_b),
        .wr(irq_wr),.addr(bus_addr[2:1]),.din(bus_dout),.be(bus_be),
        .dout(irq_dout),.ipl_a_n(a_ipl_n),.ipl_b_n(b_ipl_n));

    logic magic_wr;
    logic [7:0] magic_dout;
    s24_magic_latch magic(
        .clk(clk),.reset(reset),.wr(magic_wr),.din(bus_dout[7:0]),
        .selector(magic_sel_t'(board.magic_table)),.dout(magic_dout));

    logic [7:0] frc_count;
    logic frc_mode_data;
    // The EPM5032 owns the visible ROM-board counter and its two documented
    // clock-divider outputs. The CPU register handshake is captured below,
    // while this component models the board's 625 kHz/9 kHz timing.
    s24_romboard_epld romboard_epld(
        .clk(clk),.reset(reset),.phi1(phi1),
        .mode_write(frc_mode_write),.mode_data(frc_mode_data),
        .mode(frc_mode),.count(frc_count),.int3_n(frc_int3_n),.irq_tick(frc_tick));

    logic [4:0] index_count;
    always_ff @(posedge clk) begin
        if(reset) index_count<=0;
        // MAME advances the floppy index cadence at the start of scanline
        // 384, i.e. on the same 383->384 wrap that raises vblank.
        else if(line_wrap && vcount==10'd383)
            index_count <= index_count==5'd19 ? 5'd0 : index_count+5'd1;
    end

    logic fdc_rd,fdc_wr,fdc_wait,fdc_media_req,fdc_media_wr,fdc_media_ack;
    logic fdc_read_ack,fdc_write_ack;
    logic [2:0] fdc_addr;
    logic [7:0] fdc_dout,fdc_media_wdata,fdc_media_rdata;
    logic [7:0] fdc_media_rdata_bus;
    logic [26:0] fdc_media_addr;
    // The EPM5032 exposes only BK3..BK0 at CC/BC0001.  Keep the latch at the
    // physical four-bit width so writes to the unused upper byte bits cannot
    // become an FPGA-only readback feature or affect later ROM addressing.
    logic [3:0] rom_bank;
    logic fdc_read_busy;
    logic fdc_cache_hit;
    logic fdc_fifo_hit;
    s24_fdc fdc(
        .clk(clk),.reset(reset),.track_size({board.track_bytes_hi,board.track_bytes_lo}),
        .index_pulse(index_count!=0),.bus_rd(fdc_rd),.bus_wr(fdc_wr),.bus_addr(fdc_addr),
        .bus_din(bus_dout[7:0]),.bus_dout(fdc_dout),.bus_wait(fdc_wait),
        .media_req(fdc_media_req),.media_wr(fdc_media_wr),.media_addr(fdc_media_addr),
        .media_wdata(fdc_media_wdata),.media_rdata(fdc_media_rdata_bus),.media_ack(fdc_media_ack));
    assign fdc_media_ack = fdc_read_ack | fdc_write_ack |
        (fdc_media_req && !fdc_media_wr &&
         !fdc_read_busy && (fdc_cache_hit || fdc_fifo_hit));

    // ------------------------------- video --------------------------------
    logic tile_wr;
    logic [15:0] tile_dout;
    logic cpu_wr_pending;
    logic char_shadow_wr;
    assign char_shadow_wr = cpu_wr_pending
                            && cpu_phys[26:17] == SDR_CHAR_BASE[26:17];
    // Write-only 315-5292 side registers. System 24 MAME currently models
    // these as no-ops, but they must decode separately from tile-name RAM.
    // Retaining the values gives later die/board work a safe integration point
    // without changing the current video behavior.
    logic [15:0] tile_absel, tile_xhout, tile_xvout, tile_syncmode;
    logic [11:0] t0,t1,t2,t3;
    logic tc0,tc1,tc2,tc3;
    logic tv0,tv1,tv2,tv3;
    logic [3:0] tile_blink;
    // s24_tile's blink heuristic renders a "disabled" layer's current
    // tile/scroll data instead of leaving it blank whenever it sees that
    // layer's disable bit toggle two frames running. That is exactly right
    // for Bonanza Bros' intentional translucency blink -- the only set this
    // was verified against -- but it is a real regression for any other
    // game whose disable bit toggles every frame for an unrelated reason:
    // the heuristic then shows whatever stale content that physical
    // tilemap currently holds, which reads as one viewport bleeding into
    // another (observed on Crack Down's radar/window layers). Restrict the
    // heuristic to boards that opted into it; every other board keeps the
    // raw MAME-faithful "disabled means blank" behavior regardless of the
    // user's menu toggle.
    logic blend_capable;
    assign blend_capable = board.video_profile[0];
    s24_tile tile(
        .clk(clk),.reset(reset),.ce_pixel(ce16),.hcount(hcount),.vcount(vcount),
        .cpu_wr(tile_wr),.cpu_addr(bus_addr[15:1]),.cpu_din(bus_dout),.cpu_be(bus_be),
        .char_wr(char_shadow_wr),.char_addr(cpu_phys[16:1]),
        .char_din(bus_dout),.char_be(bus_be),
        .blend_en(flicker_blend && blend_capable),.layer_blink(tile_blink),
        .cpu_dout(tile_dout),.layer0_pixel(t0),.layer1_pixel(t1),
        .layer2_pixel(t2),.layer3_pixel(t3),.layer0_cat(tc0),.layer1_cat(tc1),
        .layer2_cat(tc2),.layer3_cat(tc3),.layer0_valid(tv0),.layer1_valid(tv1),
        .layer2_valid(tv2),.layer3_valid(tv3));
    logic [13:0] sp0,sp1,sp2,sp3,mixed,mixed_alt;
    logic [10:0] sr0,sr1,sr2,sr3;
	logic sprite_cache_invalidate;
	assign sprite_cache_invalidate=cpu_wr_pending && wr_ack &&
		cpu_phys[26:18]==SDR_SPRITE_BASE[26:18];
    s24_sprite sprite(
        .clk(clk),.reset(reset),.ce_pixel(ce16),.hcount(hcount),.vcount(vcount),
        .pixel0(sp0),.pixel1(sp1),.pixel2(sp2),.pixel3(sp3),
        .rank0(sr0),.rank1(sr1),.rank2(sr2),.rank3(sr3),
        .mem_req(p2_req),.mem_addr(p2_addr),
        .mem_data(p2_data),.mem_ack(p2_ack),
		.cache_invalidate(sprite_cache_invalidate),
		.cache_invalidate_tag(cpu_phys[17:4]));

    logic mixer_wr;
    logic [15:0] mixer_dout;
    logic display_blank;
    logic screen_flip;
    s24_mixer mixer(
        .clk(clk),.reset(reset),.cpu_wr(mixer_wr),.cpu_addr(bus_addr[4:1]),
        .cpu_din(bus_dout),.cpu_be(bus_be),.cpu_dout(mixer_dout),
        .tile0_pixel(t0),.tile1_pixel(t1),.tile2_pixel(t2),.tile3_pixel(t3),
        .tile0_cat(tc0),.tile1_cat(tc1),.tile2_cat(tc2),.tile3_cat(tc3),
        .tile0_valid(tv0),.tile1_valid(tv1),.tile2_valid(tv2),.tile3_valid(tv3),
        .sprite0_pixel(sp0),.sprite1_pixel(sp1),.sprite2_pixel(sp2),.sprite3_pixel(sp3),
        .sprite0_rank(sr0),.sprite1_rank(sr1),.sprite2_rank(sr2),.sprite3_rank(sr3),
        .tile_blink(tile_blink),
        .mixed_pixel(mixed),.mixed_pixel_alt(mixed_alt),
        .display_blank(display_blank),.screen_flip(screen_flip));
    // Hold the board-visible flip state at the core boundary.  The register
    // file is synchronous, so this changes only after a completed mixer write
    // and remains a normal dynamic video control for the framebuffer path.
    assign video_flip = screen_flip;

    typedef enum logic [3:0] {X_IDLE,X_WRITE,X_LOCAL,X_TILE,
                              X_PALETTE,X_YM,X_FDC,X_WAIT} xstate_t;
    xstate_t xs;

    // One true-dual-port palette copy serves both video lookups on ce16;
    // CPU accesses use port B only between pixel edges.
    logic [15:0] palette_word, palette_cpu_word, palette_word_alt;
    logic palette_shadow_bank, palette_display_blank, palette_shadow_bank_alt;
    logic [7:0] palette_red, palette_green, palette_blue;
    logic [7:0] palette_red_alt, palette_green_alt, palette_blue_alt;
    logic palette_blend_q, palette_cpu_done, palette_wr;
    // Preserve the accepted-write observability pulse used by boot regressions.
    assign palette_wr = palette_cpu_done && !bus_rnw;
    s24_palette_ram palette_mem(
        .clk(clk),.reset(reset),.ce_pixel(ce16),.mixed(mixed),.mixed_alt(mixed_alt),
        .blend(flicker_blend && (tile_blink != 4'b0000)),
        .display_blank(display_blank),.video_word(palette_word),
        .video_word_alt(palette_word_alt),.shadow_bank(palette_shadow_bank),
        .shadow_bank_alt(palette_shadow_bank_alt),.blend_q(palette_blend_q),
        .display_blank_q(palette_display_blank),
        .cpu_req(xs==X_PALETTE),.cpu_write(!bus_rnw),
        .cpu_addr(bus_addr[13:1]),.cpu_wdata(bus_dout),.cpu_be(bus_be),
        .cpu_rdata(palette_cpu_word),.cpu_done(palette_cpu_done));
    s24_palette pal(.palette_word(palette_word),.shadow_bank(palette_shadow_bank),
                    .red(palette_red),.green(palette_green),.blue(palette_blue));
    s24_palette pal_alt(
        .palette_word(palette_word_alt),.shadow_bank(palette_shadow_bank_alt),
        .red(palette_red_alt),.green(palette_green_alt),.blue(palette_blue_alt));

    // The two fields differ only by the blinking tilemap, so their mean is
    // exactly the steady image the original CRT produced from them.
    logic [7:0] blended_red, blended_green, blended_blue;
    always_comb begin
        blended_red   = palette_blend_q
                      ? 8'((({1'b0,palette_red}   + {1'b0,palette_red_alt})   >> 1))
                      : palette_red;
        blended_green = palette_blend_q
                      ? 8'((({1'b0,palette_green} + {1'b0,palette_green_alt}) >> 1))
                      : palette_green;
        blended_blue  = palette_blend_q
                      ? 8'((({1'b0,palette_blue}  + {1'b0,palette_blue_alt})  >> 1))
                      : palette_blue;
    end
    always_comb begin
        red   = (reset || palette_display_blank) ? 8'h00 : blended_red;
        green = (reset || palette_display_blank) ? 8'h00 : blended_green;
        blue  = (reset || palette_display_blank) ? 8'h00 : blended_blue;
    end

    // --------------------------- board interconnect ------------------------
    function automatic logic is_tile_window(input logic [23:0] a);
        // MAME: 200000-20ffff mirrored by 110000. A20 and A16 are mirror
        // bits; A19:A17 must remain zero.
        is_tile_window = (a[23:21] == 3'b001) && (a[19:17] == 3'b000);
    endfunction
    function automatic logic is_tile_absel(input logic [23:0] a);
        // 220000-220001 mirrored by 11fffe.
        is_tile_absel = ((a & 24'hee0000) == 24'h220000);
    endfunction
    function automatic logic is_tile_xhout(input logic [23:0] a);
        // 240000-240001 mirrored by 11fffe.
        is_tile_xhout = ((a & 24'hee0000) == 24'h240000);
    endfunction
    function automatic logic is_tile_xvout(input logic [23:0] a);
        // 260000-260001 mirrored by 10fffe.
        is_tile_xvout = ((a & 24'hef0000) == 24'h260000);
    endfunction
    function automatic logic is_tile_syncmode(input logic [23:0] a);
        // 270000-270001 mirrored by 10fffe.
        is_tile_syncmode = ((a & 24'hef0000) == 24'h270000);
    endfunction
    function automatic logic is_fdc_window(input logic [23:0] a);
        // B00000-B0000f mirrored by 07fff0: the full B00000-B7ffff block.
        is_fdc_window = (a[23:19] == 5'b10110);
    endfunction
    function automatic logic is_sprite_window(input logic [23:0] a);
        // MAME: 600000-63ffff mirrored by 180000. A20 and A19 are mirror
        // bits, while A18 remains decoded and must be zero.
        is_sprite_window = ((a & 24'he40000) == 24'h600000);
    endfunction
    function automatic logic is_memory(input logic cpu,input logic [23:0] a);
        if (a < 24'h200000) is_memory=1;
        // Both CPUs can address both shared work-RAM banks through the common
        // high mirrors.  MAME common_map installs these before the two
        // CPU-specific low windows.
        else if (a >= 24'hf00000) is_memory=1;
        else if (a[23:21]==3'b001 && a[19]) is_memory=1; // character RAM
        else if (is_sprite_window(a)) is_memory=1;       // sprite RAM
        else if ((a>=24'hb80000&&a<=24'hbbffff)||(a>=24'hc80000&&a<=24'hcbffff))
            is_memory=board.has_romboard;
        else is_memory=0;
    endfunction
    function automatic logic is_writable(input logic cpu,input logic [23:0] a);
        if (a>=24'hf00000) is_writable=1;
        // MAME common_map() installs the 080000-0fffff Work-A window in
        // both CPU maps. It is shared RAM, not CPU-A-private memory.
        else if (a>=24'h080000&&a<24'h100000) is_writable=1;
        else if (cpu && a<24'h080000) is_writable=1;
        else if (a[23:21]==3'b001 && a[19]) is_writable=1;
        else if (is_sprite_window(a)) is_writable=1;
        else is_writable=0;
    endfunction
    function automatic [26:0] physical(
        input logic cpu,
        input logic [23:0] a,
        input logic [3:0] bank,
        input logic [1:0] romboard_profile
    );
        if (a >= 24'hf80000)
            physical=SDR_WORKA_BASE+{9'd0,a[17:0]};
        else if (a >= 24'hf00000)
            physical=SDR_WORKB_BASE+{9'd0,a[17:0]};
        else if (a < 24'h080000)
            physical=(cpu?SDR_WORKB_BASE:SDR_BOOT_BASE)+{9'd0,a[17:0]};
        else if (a < 24'h100000) physical=SDR_WORKA_BASE+{9'd0,a[17:0]};
        else if (a < 24'h200000) physical=SDR_BOOT_BASE+{9'd0,a[17:0]};
        // System 24 populates 128 KB of character RAM. A18:A17 are ignored
        // throughout the mirrored 512 KB CPU window (Model 1/2 populate more).
        else if (a[23:21]==3'b001 && a[19]) physical=SDR_CHAR_BASE+{10'd0,a[16:0]};
        else if (is_sprite_window(a)) physical=SDR_SPRITE_BASE+{9'd0,a[17:0]};
        else physical=SDR_ROMBOARD_BASE+
                      {5'd0,romboard_offset(romboard_profile,bank,a[17:0])};
    endfunction

    // Each physical CPU bus has its own read path into SDRAM. Keep a request
    // occupied until the CPU front-end has observed the completion pulse, so
    // its level-held AS cycle cannot be launched twice. CPU-B opcode reads add
    // the FD1094 stage after p3 returns the encrypted word.
    typedef enum logic [2:0] {MR_IDLE,MR_LOOKUP,MR_SDRAM,MR_DECRYPT,MR_DROP} mrstate_t;
    mrstate_t a_mrstate,b_mrstate;
    always_ff @(posedge clk) begin
        a_mem_ack<=1'b0;
        b_mem_ack<=1'b0;
        fd_start<=1'b0;
        fd_key_start<=1'b0;
        bc_hit_record<=1'b0;
        bc_fill<=1'b0;
        ac_fill<=1'b0;
        if(reset) begin
            a_mrstate<=MR_IDLE;
            b_mrstate<=MR_IDLE;
            a_mem_din<=16'h0000;
            b_mem_din<=16'h0000;
            p0_req<=1'b0;
            p3_req<=1'b0;
            p0_addr<='0;
            p3_addr<='0;
            fd_ciphertext<=16'h0000;
        end else begin
            case(a_mrstate)
                MR_IDLE: if(a_mem_req) begin
                    if(A_OPCACHE_ENABLE) a_mrstate<=MR_LOOKUP;
                    else begin
                        p0_addr<=word_address(physical(1'b0,a_mem_addr,rom_bank,
                                                        board.romboard_profile));
                        p0_req<=1'b1;
                        a_mrstate<=MR_SDRAM;
                    end
                end
                MR_LOOKUP: begin
                    if(ac_hit) begin
                        a_mem_din<=ac_hit_data;
                        a_mem_ack<=1'b1;
                        a_mrstate<=MR_DROP;
                    end else begin
                        p0_addr<=word_address(physical(1'b0,a_mem_addr,rom_bank,
                                                        board.romboard_profile));
                        p0_req<=1'b1;
                        a_mrstate<=MR_SDRAM;
                    end
                end
                MR_SDRAM: if(p0_ack) begin
                    p0_req<=1'b0;
                    a_mem_din<=p0_data;
                    a_mem_ack<=1'b1;
                    ac_fill<=A_OPCACHE_ENABLE && ac_window;
                    a_mrstate<=MR_DROP;
                end
                MR_DROP: if(!a_mem_req) a_mrstate<=MR_IDLE;
                default: a_mrstate<=MR_IDLE;
            endcase

            case(b_mrstate)
                // One lookup cycle before the SDRAM launch: the opcode
                // cache's tag/data RAMs register the fetch address at the
                // end of this cycle, so the hit decision is valid during
                // MR_LOOKUP.  A hit acknowledges in ~4 clk_sys from AS
                // instead of ~18; a miss pays one extra cycle, which a hit
                // rate above ~6% repays.
                MR_IDLE: if(b_mem_req) b_mrstate<=MR_LOOKUP;
                MR_LOOKUP: begin
                    if(bc_hit) begin
                        b_mem_din<=bc_hit_data;
                        b_mem_ack<=1'b1;
                        // Replay the fetch into the FD1094 CMP/history
                        // tracker, which this hit bypassed.  A hit issues
                        // no key_start, so the decryptor stays in F_IDLE
                        // for the whole transaction.
                        bc_hit_record<=board.has_fd1094;
                        b_mrstate<=MR_DROP;
                    end else begin
                        p3_addr<=word_address(physical(1'b1,b_mem_addr,rom_bank,
                                                        board.romboard_profile));
                        p3_req<=1'b1;
                        // Same predicate the MR_SDRAM arm below uses to raise
                        // fd_start, evaluated on the identical registered
                        // b_mem_* values (s24_cpu_bus holds them for the whole
                        // transaction). Kicking the key-RAM read off here lets
                        // it retire behind the SDRAM round trip instead of
                        // adding its latency on top -- see s24_fd1094.sv's
                        // key_start port comment.
                        if(board.has_fd1094 && b_mem_fc[1] &&
                           b_mem_addr<24'h100000) fd_key_start<=1'b1;
                        b_mrstate<=MR_SDRAM;
                    end
                end
                MR_SDRAM: if(p3_ack) begin
                    p3_req<=1'b0;
                    if(board.has_fd1094 && b_mem_fc[1] &&
                       b_mem_addr<24'h100000) begin
                        fd_ciphertext<=p3_data;
                        fd_start<=1'b1;
                        b_mrstate<=MR_DECRYPT;
                    end else begin
                        b_mem_din<=p3_data;
                        b_mem_ack<=1'b1;
                        // In-window plain fetch (non-FD1094 board): cache
                        // the raw word under the constant zero state tag.
                        bc_fill<=bc_window;
                        b_mrstate<=MR_DROP;
                    end
                end
                MR_DECRYPT: if(fd_done) begin
                    b_mem_din<=fd_plaintext;
                    b_mem_ack<=1'b1;
                    // Cache the decrypted word under the state the decrypt
                    // consumed (fd_state_used), never current_state -- a
                    // CMP-driven state change can land mid-flight.
                    bc_fill<=bc_window;
                    b_mrstate<=MR_DROP;
                end
                MR_DROP: if(!b_mem_req) b_mrstate<=MR_IDLE;
                default: b_mrstate<=MR_IDLE;
            endcase
        end
    end

    // MAME's read_xy handler pulses CS low before selecting axis/byte and
    // reading the uPD4701A. Keep that edge tied to the accepted bus request;
    // X_LOCAL returns the now-latched payload on the following clock.
    always_comb begin
        upd0_read=1'b0;
        upd1_read=1'b0;
        if (xs==X_IDLE && bus_req && bus_rnw && !bus_addr[4] &&
            board.has_upd4701) begin
            if (bus_addr[3] && board.hotrod_io) upd1_read=1'b1;
            else if (!bus_addr[3]) upd0_read=1'b1;
        end
    end
    // The MB89311 exposes a local data register. Keep the complete SDRAM
    // word returned for a floppy byte so the immediately following byte
    // read (the other lane) does not become a second media transaction.
    logic fdc_cache_valid;
    logic [26:0] fdc_cache_addr;
    logic [15:0] fdc_cache_data;
    localparam integer FDC_PREFETCH_DEPTH = 64;
    logic [15:0] fdc_pf_data [0:FDC_PREFETCH_DEPTH-1];
    logic [26:0] fdc_pf_addr [0:FDC_PREFETCH_DEPTH-1];
    logic [5:0] fdc_pf_rd,fdc_pf_wr;
    logic [6:0] fdc_pf_count;
    logic fdc_p4_prefetch,fdc_pf_have_stream,fdc_pf_discard;
    logic [26:0] fdc_pf_next_addr;
    logic fdc_pf_push,fdc_pf_pop;
    // The game can modify the floppy image through the shared CPU SDRAM
    // window as well as through the FDC's byte-write request.  Any such
    // write must invalidate read-ahead before a following FDC byte read can
    // observe the old word.
    logic fdc_floppy_write;
    assign fdc_floppy_write = wr_req &&
                               (wr_addr >= word_address(SDR_FLOPPY_BASE)) &&
                               (wr_addr < word_address(SDR_FDKEY_BASE));

    assign fdc_cache_hit = fdc_cache_valid && !fdc_floppy_write &&
                           (fdc_cache_addr ==
                            word_address(SDR_FLOPPY_BASE+fdc_media_addr));
    assign fdc_fifo_hit = (fdc_pf_count != 0) &&
                          !fdc_floppy_write &&
                          !fdc_pf_discard &&
                          (fdc_pf_addr[fdc_pf_rd] ==
                           word_address(SDR_FLOPPY_BASE+fdc_media_addr));
    assign fdc_pf_push = p4_ack && p4_req && fdc_p4_prefetch &&
                         !fdc_pf_discard &&
                         !fdc_floppy_write;
    assign fdc_pf_pop = fdc_media_req && !fdc_media_wr &&
                        !fdc_read_busy && !fdc_cache_hit && fdc_fifo_hit;
    assign fdc_media_rdata_bus = fdc_cache_hit ?
                                  (fdc_media_addr[0] ?
                                   fdc_cache_data[15:8] : fdc_cache_data[7:0]) :
                                  fdc_fifo_hit ?
                                  (fdc_media_addr[0] ?
                                   fdc_pf_data[fdc_pf_rd][15:8] :
                                   fdc_pf_data[fdc_pf_rd][7:0]) :
                                  fdc_media_rdata;
    logic fdc_read_odd;

    // FDC read service uses p4; write service shares the SDRAM write port.
    // The MB89311 has a local data register.  Once the first word of a
    // sequential read has returned, prefetch following words into a bounded
    // FIFO so the CPU-B floppy stream is not charged one SDRAM round trip per
    // byte.  A mismatch (new command, track change or write) flushes it.
    always_ff @(posedge clk) begin
        fdc_read_ack<=0;
        if(reset) begin
            p4_req<=0;
            p4_addr<=0;
            fdc_media_rdata<=0;
            fdc_read_busy<=0;
            fdc_read_odd<=0;
            fdc_cache_valid<=0;
            fdc_cache_addr<=0;
            fdc_cache_data<=0;
            fdc_pf_rd<=0;
            fdc_pf_wr<=0;
            fdc_pf_count<=0;
            fdc_p4_prefetch<=0;
            fdc_pf_have_stream<=0;
            fdc_pf_discard<=0;
            fdc_pf_next_addr<=0;
        end
        else begin
            // A media write invalidates all read-ahead state.  Do not cancel
            // an already accepted p4 cycle; discard its result on completion.
            if(fdc_floppy_write) begin
                fdc_cache_valid<=0;
                fdc_pf_count<=0;
                fdc_pf_rd<=0;
                fdc_pf_wr<=0;
                fdc_pf_have_stream<=0;
                if(p4_req)
                    fdc_pf_discard<=1;
            end

            // A cached FIFO word is consumed combinationally as the FDC
            // acknowledges the byte.  Promote it to the one-word cache so
            // the opposite byte lane is still a zero-latency hit.
            if(fdc_pf_pop) begin
                fdc_cache_valid<=1;
                fdc_cache_addr<=fdc_pf_addr[fdc_pf_rd];
                fdc_cache_data<=fdc_pf_data[fdc_pf_rd];
                fdc_pf_rd<=fdc_pf_rd+1'b1;
            end

            // A request that is not covered by either read cache starts one
            // demand read.  If a speculative read is in flight for another
            // word, let it finish and discard it before issuing this read.
            if(fdc_media_req && !fdc_media_wr && !fdc_read_busy &&
               !fdc_cache_hit && !fdc_fifo_hit && !p4_req) begin
                p4_req<=1;
                p4_addr<=word_address(SDR_FLOPPY_BASE+fdc_media_addr);
                fdc_read_odd<=fdc_media_addr[0];
                fdc_read_busy<=1;
                fdc_p4_prefetch<=0;
                fdc_cache_valid<=0;
                fdc_pf_count<=0;
                fdc_pf_rd<=0;
                fdc_pf_wr<=0;
                fdc_pf_have_stream<=0;
                fdc_pf_discard<=0;
                fdc_pf_next_addr<=word_address(SDR_FLOPPY_BASE+fdc_media_addr)+1'b1;
            end
            else if(fdc_media_req && !fdc_media_wr && !fdc_read_busy &&
                    !fdc_cache_hit && !fdc_fifo_hit && p4_req &&
                    fdc_p4_prefetch &&
                    p4_addr != word_address(SDR_FLOPPY_BASE+fdc_media_addr)) begin
                fdc_pf_discard<=1;
            end

            if(p4_ack && p4_req) begin
                p4_req<=0;
                fdc_p4_prefetch<=0;
                if(fdc_p4_prefetch) begin
                    // A write may arrive on the same edge as a speculative
                    // read response. Never enqueue that pre-write word.
                    if(fdc_pf_discard || fdc_floppy_write) begin
                        fdc_pf_count<=0;
                        fdc_pf_rd<=0;
                        fdc_pf_wr<=0;
                        fdc_pf_have_stream<=0;
                        fdc_pf_discard<=0;
                    end
                    else begin
                        fdc_pf_data[fdc_pf_wr]<=p4_data;
                        fdc_pf_addr[fdc_pf_wr]<=p4_addr;
                        fdc_pf_wr<=fdc_pf_wr+1'b1;
                    end
                end
                else begin
                    if(fdc_pf_discard || fdc_floppy_write) begin
                        fdc_read_ack<=0;
                        fdc_cache_valid<=0;
                        fdc_pf_have_stream<=0;
                        fdc_pf_discard<=0;
                    end else begin
                        fdc_read_ack<=1;
                        fdc_media_rdata<=fdc_read_odd?p4_data[15:8]:p4_data[7:0];
                        fdc_cache_valid<=1;
                        fdc_cache_addr<=p4_addr;
                        fdc_cache_data<=p4_data;
                        fdc_pf_have_stream<=1;
                        fdc_pf_next_addr<=p4_addr+1'b1;
                    end
                end
            end

            // Keep filling only while the FDC is idle and the FIFO has room.
            // One p4 request is shared by demand reads and this read-ahead.
            // Sprite bursts have a hard scanline deadline; floppy read-ahead
            // is speculative and may use only vertical-blank AV bandwidth.
            // Merely checking p2_req is insufficient: a one-word prefetch can
            // otherwise slip into every gap between the renderer's 128-bit
            // cache fills and cumulatively make the producer miss a line.
            // Demand FDC reads retain the arbiter's normal p2/p4 fairness.
            if(fdc_pf_have_stream && !p4_req && !fdc_media_req && vblank &&
               !p2_req &&
               !fdc_pf_discard && fdc_pf_count < 7'd64) begin
                p4_req<=1;
                p4_addr<=fdc_pf_next_addr;
                fdc_p4_prefetch<=1;
                fdc_pf_next_addr<=fdc_pf_next_addr+1'b1;
            end

            if(fdc_floppy_write) begin
                // The write flush above must win over a same-edge prefetch
                // response; otherwise the stale word reappears in the FIFO.
                fdc_pf_count<=0;
            end else begin
                case({fdc_pf_push,fdc_pf_pop})
                    2'b10: fdc_pf_count<=fdc_pf_count+1'b1;
                    2'b01: fdc_pf_count<=fdc_pf_count-1'b1;
                    default: ;
                endcase
            end

            if(fdc_read_busy && !fdc_media_req)
                fdc_read_busy<=0;
        end
    end

    always_comb begin
        wr_req=cpu_wr_pending | (fdc_media_req&&fdc_media_wr);
        if(fdc_media_req&&fdc_media_wr) begin
            wr_addr=word_address(SDR_FLOPPY_BASE+fdc_media_addr);
            wr_data={fdc_media_wdata,fdc_media_wdata};
            wr_be=fdc_media_addr[0]?2'b10:2'b01;
        end else begin
            wr_addr=cpu_phys[26:1];wr_data=bus_dout;wr_be=bus_be;
        end
    end

    always_ff @(posedge clk) begin
        bus_ack<=0;io_rd<=0;io_wr<=0;irq_rd_a<=0;irq_rd_b<=0;irq_wr<=0;
        magic_wr<=0;tile_wr<=0;mixer_wr<=0;fdc_rd<=0;fdc_wr<=0;
        adc0_select<=0;adc1_select<=0;adc0_shift<=0;adc1_shift<=0;
        frc_mode_write<=0;frc_ack_write<=0;bc_snoop<=0;
        if(reset) begin
            xs<=X_IDLE;bus_din<=16'h0000;
            cpu_wr_pending<=0;cpu_phys<=0;rom_bank<=0;frc_mode_data<=0;
            fdc_addr<=0;
            tile_absel<=0;tile_xhout<=0;tile_xvout<=0;tile_syncmode<=0;
            ym_write_pending<=0;ym_addr_q<=0;ym_data_q<=0;
            irq_read_pending<=0;
            upd_read_pending<=0;upd_read_select<=0;
        end else begin
            if (ym_write_accepted)
                ym_write_pending <= 1'b0;
            case(xs)
            X_IDLE: if(bus_req) begin
                irq_read_pending<=0;
                // A00000-AFFFFF lives on CPU A's physical bus. A CPU-B
                // crossing waits for an in-flight CPU-A memory cycle; when A
                // is idle there is no added delay, matching the measured STOP
                // exception without trying to infer the STOP instruction.
                if(bus_cpu && bus_addr[23:20]==4'ha && a_mem_req) begin
                    // Hold X_IDLE and leave the shared request pending.
                end else if(is_memory(bus_cpu,bus_addr)) begin
                    cpu_phys<=physical(bus_cpu,bus_addr,rom_bank,
                                       board.romboard_profile);
                    if(!bus_rnw && is_writable(bus_cpu,bus_addr)) begin
                        cpu_wr_pending<=1;xs<=X_WRITE;
                        // Invalidate any opcode-cache line this store may
                        // cover.  Both CPUs' stores funnel through here with
                        // the PHYSICAL address, so CPU-A patching CPU-B's
                        // program through its f00000/f80000 windows is
                        // caught; the cache filters to WORKA/WORKB itself.
                        bc_snoop<=1;
                    end else begin bus_din<=16'h0000;xs<=X_LOCAL; end
                end else if(is_tile_window(bus_addr)) begin
                    if(bus_rnw) xs<=X_TILE;
                    else begin tile_wr<=1;xs<=X_LOCAL; end
                end else if(is_tile_absel(bus_addr)) begin
                    bus_din<=16'h0000;
                    if(!bus_rnw)tile_absel<=merge16(tile_absel,bus_dout,bus_be);
                    xs<=X_LOCAL;
                end else if(is_tile_xhout(bus_addr)) begin
                    bus_din<=16'h0000;
                    if(!bus_rnw)tile_xhout<=merge16(tile_xhout,bus_dout,bus_be);
                    xs<=X_LOCAL;
                end else if(is_tile_xvout(bus_addr)) begin
                    bus_din<=16'h0000;
                    if(!bus_rnw)tile_xvout<=merge16(tile_xvout,bus_dout,bus_be);
                    xs<=X_LOCAL;
                end else if(is_tile_syncmode(bus_addr)) begin
                    bus_din<=16'h0000;
                    if(!bus_rnw)tile_syncmode<=merge16(tile_syncmode,bus_dout,bus_be);
                    xs<=X_LOCAL;
                end else if(bus_addr[23:21]==3'b010 && !bus_addr[14]) begin
                    xs<=X_PALETTE;
                end else if(bus_addr[23:21]==3'b010 && bus_addr[14]) begin
                    bus_din<=mixer_dout;if(!bus_rnw)mixer_wr<=1;xs<=X_LOCAL;
                end else if((bus_addr[23:21]==3'b100)&&bus_addr[8:6]==0) begin
                    // System 24 leaves the program-space unmapped value low;
                    // the 315-5296 occupies only D7:D0.  A D15:D8-only read
                    // therefore completes with zero without touching the
                    // low-lane device.
                    bus_din<={8'h00,io_dout};
                    io_rd<=bus_rnw&&bus_be[0];
                    io_wr<=~bus_rnw&&bus_be[0];
                    xs<=X_LOCAL;
                end else if((bus_addr[23:21]==3'b100)&&bus_addr[8:6]==1) begin
                    // The optional I/O daughterboard handler is a deliberate
                    // exception to the default-low map and returns 0xffff.
                    bus_din<=16'hffff;xs<=X_LOCAL;
                end else if((bus_addr[23:21]==3'b100)&&
                            bus_addr[8:2]==7'b1000000) begin
                    bus_din<={8'h00,ym_dout};
                    if(bus_rnw || !bus_be[0]) xs<=X_LOCAL;
                    else begin
                        ym_addr_q<=bus_addr[1];
                        ym_data_q<=bus_dout[7:0];
                        ym_write_pending<=1'b1;
                        xs<=X_YM;
                    end
                end else if(bus_addr[23:19]==5'b11000 && !bus_addr[4] &&
                            board.has_upd4701 &&
                            (board.hotrod_io || !bus_addr[3])) begin
                    bus_din<={8'h00,bus_addr[3]?upd1_dout:upd0_dout};
                    upd_read_pending<=upd0_read || upd1_read;
                    upd_read_select<=upd1_read;
                    xs<=X_LOCAL;
                end else if(bus_addr[23:19]==5'b11000 && bus_addr[4] &&
                            board.has_adc) begin
                    bus_din<={8'h00,bus_addr[1]?adc1_dout:adc0_dout};
                    if(bus_be[0]) begin
                        if(bus_addr[1]) begin
                            adc1_shift<=bus_rnw;adc1_select<=~bus_rnw;
                        end else begin
                            adc0_shift<=bus_rnw;adc0_select<=~bus_rnw;
                        end
                    end
                    xs<=X_LOCAL;
                end else if(bus_addr[23:20]==4'ha) begin
                    bus_din<=irq_dout;irq_rd_a<=bus_rnw&&!bus_cpu;irq_rd_b<=bus_rnw&&bus_cpu;
                    irq_wr<=~bus_rnw;irq_read_pending<=bus_rnw;xs<=X_LOCAL;
                // MAME mirrors the two FDC blocks by 0x07fff0, covering the
                // complete B00000-B7FFFF region. A3 selects data/status and
                // A2:A1 select the four word registers in the data block.
                end else if(is_fdc_window(bus_addr)) begin
                    fdc_addr<=bus_addr[3] ? 3'd4 : {1'b0,bus_addr[2:1]};
                    fdc_rd<=bus_rnw;
                    // segas24.cpp accepts writes only through D7:D0.
                    // A high-byte-only 68000 write must leave the FDC intact.
                    fdc_wr<=~bus_rnw && bus_be[0];
                    xs<=X_FDC;
                end else if((bus_addr[23:18]==6'b101111)||
                            (bus_addr[23:18]==6'b110011)) begin
                    // The mapped registers live at odd byte addresses. The
                    // shared bus carries the aligned word address, so A[2:1]
                    // selects BC/CC0001,3,5,7 respectively.
                    case(bus_addr[2:1])
                        2'd0: begin
                            // The BC/CC0001 bank latch is populated only on
                            // ROM-board configurations. Floppy-only boards
                            // leave this byte open, matching rombd_common_map.
                            bus_din<=board.has_romboard?{12'h000,rom_bank}:16'h0000;
                            if(!bus_rnw && bus_be[0] && board.has_romboard)
                                rom_bank<=bus_dout[3:0];
                        end
                        2'd1: begin
                            bus_din<={15'd0,frc_mode};
                            if(!bus_rnw && bus_be[0]) begin
                                frc_mode_data<=bus_dout[0];
                                frc_mode_write<=1;
                            end
                        end
                        2'd2: begin
                            bus_din<={8'h00,frc_count};
                            if(!bus_rnw && bus_be[0])frc_ack_write<=1;
                        end
                        default: begin
                            bus_din<={8'h00,magic_dout};
                            if(!bus_rnw && bus_be[0])magic_wr<=1;
                        end
                    endcase
                    xs<=X_LOCAL;
                end else begin bus_din<=16'h0000;xs<=X_LOCAL; end
            end
            X_WRITE: if(wr_ack) begin cpu_wr_pending<=0;bus_ack<=1;xs<=X_WAIT;end
            X_LOCAL: begin
                // MAME's irq_r synchronizes the timer when the read handler
                // runs.  Re-sample the combinational timer payload here,
                // after the request phase, so a line-boundary update cannot
                // return the stale value captured at X_IDLE.
                if(irq_read_pending) bus_din<=irq_dout;
                if(upd_read_pending) begin
                    bus_din<={8'h00,upd_read_select?upd1_dout:upd0_dout};
                    upd_read_pending<=1'b0;
                end
                bus_ack<=1;xs<=X_WAIT;
            end
            X_TILE: begin bus_din<=tile_dout;bus_ack<=1;xs<=X_WAIT;end
            X_PALETTE: if(palette_cpu_done) begin
                bus_din<=palette_cpu_word;bus_ack<=1;xs<=X_WAIT;
            end
            X_YM: if(!ym_write_pending) begin bus_ack<=1;xs<=X_WAIT;end
            // segas24_state::fdc_r/status_r return a 16-bit 0x00xx value
            // when a floppy controller is populated.  With no media profile
            // the handler returns 0xffff instead.
            X_FDC: if(!fdc_wait) begin
                bus_din<={board.has_floppy ? 8'h00 : 8'hff,fdc_dout};
                bus_ack<=1;xs<=X_WAIT;
            end
            // bus_ack is registered in this clock domain.  The arbiter drops
            // bus_req one edge later, so do not treat that still-high request
            // as a new transaction on the intervening edge.
            X_WAIT: if(!bus_req) xs<=X_IDLE;
            default: xs<=X_IDLE;
            endcase
        end
    end

    // Complete a floppy write byte after SDRAM accepts it.
    always_ff @(posedge clk) begin
        fdc_write_ack <= 1'b0;
        floppy_written <= 1'b0;
        if (reset) begin
            fdc_write_ack <= 1'b0;
            floppy_written <= 1'b0;
        end else if (fdc_media_req && fdc_media_wr && wr_ack) begin
            fdc_write_ack <= 1'b1;
            floppy_written <= 1'b1;
        end
    end

    // DAC is port H. MAME configures the YM channel and unsigned R-2R DAC
    // route at equal 0.50 gain into each corresponding stereo output.
    logic signed [15:0] dac_sample;
    assign dac_sample={~io_port_out[63],io_port_out[62:56],8'h00};
    function automatic logic signed [15:0] mix_sat(
        input logic signed [15:0] fm,
        input logic signed [15:0] dac
    );
        logic signed [16:0] sum;
        begin
            sum = ($signed({fm[15],fm}) >>> 1) +
                  ($signed({dac[15],dac}) >>> 1);
            if (sum > 17'sd32767)       mix_sat = 16'sh7fff;
            else if (sum < -17'sd32768) mix_sat = 16'sh8000;
            else                        mix_sat = sum[15:0];
        end
    endfunction
    logic signed [15:0] mixed_l,mixed_r,filtered_l,filtered_r;
    assign mixed_l=mix_sat(ym_l,dac_sample);
    assign mixed_r=mix_sat(ym_r,dac_sample);
    s24_audio_lpf audio_filter_l(
        .clk(clk),.reset(reset),.sample_strobe(ym_sample_l),
        .sample_in(mixed_l),.sample_out(filtered_l));
    s24_audio_lpf audio_filter_r(
        .clk(clk),.reset(reset),.sample_strobe(ym_sample_r),
        .sample_in(mixed_r),.sample_out(filtered_r));
    assign audio_l=pause?16'sd0:filtered_l;
    assign audio_r=pause?16'sd0:filtered_r;

endmodule
