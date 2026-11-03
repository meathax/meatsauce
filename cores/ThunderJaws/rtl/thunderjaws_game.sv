// SPDX-License-Identifier: GPL-3.0-or-later
// Framework-independent live game integration. ROM ports are held transactions;
// framework/SDRAM attaches outside this module. The renderer currently contains
// PF1/PF2/alpha; MO/priority/stain joins at the palette-index stage next.
module thunderjaws_game #(parameter integer ENABLE_SOUND=1,ENABLE_MOTION=1,VIDEO_SNAPSHOT_ENABLE=1) (
    input wire flip_request,
    input wire clk_sys,init_reset,game_reset,rom_loading,
    input wire pause_request,
    output wire paused,
    input wire score_read,score_write,
    input wire [23:0] score_address,
    input wire [7:0] score_write_data,
    output wire [7:0] score_read_data,
    output wire score_data_ready,score_signature_ready,score_busy,score_error,
    input wire [1:0] p1_buttons,p2_buttons,
    input wire [3:0] p1_directions,p2_directions,
    input wire service_test,
    input wire [2:0] coin,
    output wire cpu_rom_valid,
    input wire cpu_rom_ready,
    output wire cpu_rom_owner,
    output wire [23:1] cpu_rom_address,
    input wire cpu_rom_response_valid,
    input wire [15:0] cpu_rom_response_data,
    output wire pf1_rom_fetch,pf2_rom_fetch,
    output wire [17:0] pf1_rom_address,pf2_rom_address,
    input wire [31:0] pf1_rom_data,pf2_rom_data,
    input wire pf1_rom_valid,pf2_rom_valid,
    output wire mo_rom_fetch,
    output wire [17:0] mo_rom_address,
    input wire [31:0] mo_rom_data,
    input wire mo_rom_valid,
    output wire [14:0] alpha_rom_address,
    input wire [15:0] alpha_rom_data,
    input wire sound_rom_wr,
    input wire [15:0] sound_rom_address,
    input wire [7:0] sound_rom_data,
    output wire oki_rom_req,
    output wire [17:0] oki_rom_address,
    input wire oki_rom_ack,
    input wire [7:0] oki_rom_data,
    input wire eeprom_restore,eeprom_load_we,
    input wire [10:0] eeprom_load_address,eeprom_dump_address,
    input wire [7:0] eeprom_load_data,
    output wire [7:0] eeprom_dump_data,
    output wire eeprom_modified,
    output reg video_ce,video_de,
    output reg [8:0] video_h,video_v,
    output reg [7:0] video_r,video_g,video_b,
    output reg signed [15:0] audio_l,audio_r,
    output wire video_fault,watchdog_expired,
    output wire [8:0] beam_h,beam_v
);
    wire ce_pixel,hblank,vblank,visible,line_start,frame_zero,vblank_start;
    wire [8:0] next_line;
    wire bus_valid,bus_ready,bus_owner,bus_read,bus_reply;
    wire [23:1] bus_address;
    wire [1:0] bus_lanes;
    wire [15:0] bus_data,bus_reply_data;
    wire [14:0] bus_select;
    wire extra_hold,watchdog_kick,sound_reset,sound_command,sound_ack;
    wire [7:0] command_data,response_data;
    wire response_full,command_full,irq6;
    wire [2:0] alpha_bank;
    wire [15:0] port0,port1,port2,irq_word,irq_previous;
    wire irq_arm,irq_ack,irq4;
    wire [8:0] pf1_x,pf1_y,pf2_x,pf2_y;
    wire [14:0] p1_code_a,p1_attr_a,p2_code_a,p2_attr_a,alpha_a;
    wire [15:0] p1_code,p1_attr,p2_code,p2_attr,alpha_data;
    wire p1_fetch,p2_fetch,alpha_fetch,p1_rom_late,p2_rom_late;
    wire [2:0] memory_late;
    wire [9:0] background_palette;
    wire [12:0] background_pixel;
    wire [8:0] alpha_pixel;
    wire [10:0] mixed_palette,motion_pixel;
    wire [8:0] mo_x,mo_y;
    wire mo_request,mo_ready,mo_reply;
    wire [14:0] mo_address;
    wire [63:0] mo_data;
    wire mo_over,mo_budget;
    wire score_ram_valid,score_ram_ready,score_ram_read,score_ram_reply;
    wire [14:0] score_ram_address;
    wire [1:0] score_ram_lanes;
    wire [15:0] score_ram_data,score_ram_reply_data;
    reg [10:0] palette_address;
    wire [15:0] palette_data;
    wire [7:0] red,green,blue;
    wire board_reset=game_reset || watchdog_expired;
    wire cpu_reset=board_reset || rom_loading || eeprom_restore;
    wire [2:0] main_ipl=irq6 ? 3'b001 : irq4 ? 3'b011 : 3'b111;
    wire [2:0] extra_ipl=irq4 ? 3'b011 : 3'b111;
    wire signed [15:0] ym1,ym2;
    wire signed [17:0] oki;
    wire signed [15:0] audio_mix;
    thunderjaws_audio_output u_audio_output(.ym1(ym1),.ym2(ym2),.oki(oki),.audio(audio_mix));
    assign cpu_rom_owner=bus_owner;
    assign cpu_rom_address=bus_address;
    wire stain_fault;
    reg flip_screen;
    always @(posedge clk_sys)begin
        if(init_reset)flip_screen<=0;
        else if(vblank_start)flip_screen<=flip_request;
    end
    localparam integer SNAPSHOT_ACTIVE=VIDEO_SNAPSHOT_ENABLE && ENABLE_MOTION;
    wire snapshot_initialized,snapshot_fault;
    wire snapshot_start=SNAPSHOT_ACTIVE && vblank_start;
    wire render_reset=init_reset || rom_loading || !snapshot_initialized;
    reg [8:0] view_p1x,view_p1y,view_p2x,view_p2y,view_mox,view_moy;
    reg [2:0] view_alpha_bank;
    always @(posedge clk_sys)begin
        if(init_reset)begin view_p1x<=0;view_p1y<=0;view_p2x<=0;view_p2y<=0;view_mox<=0;view_moy<=0;view_alpha_bank<=0;end
        else if(snapshot_start)begin
            view_p1x<=pf1_x;view_p1y<=pf1_y;view_p2x<=pf2_x;view_p2y<=pf2_y;
            view_mox<=mo_x;view_moy<=mo_y;view_alpha_bank<=alpha_bank;
        end
    end
    assign video_fault=|memory_late || p1_rom_late || p2_rom_late || mo_over || mo_budget || stain_fault || snapshot_fault;
    thunderjaws_cpu_pair #(.RECOVERY_ENABLE(1)) cpus(.clk_sys(clk_sys),.init_reset(init_reset),
        .pause_request(pause_request || score_busy),.paused(paused),
        .main_reset(cpu_reset),.extra_reset(cpu_reset || extra_hold),.main_ipl_n(main_ipl),.extra_ipl_n(extra_ipl),
        .backend_valid(bus_valid),.backend_ready(bus_ready),.backend_owner(bus_owner),.backend_address(bus_address),
        .backend_read(bus_read),.backend_lanes(bus_lanes),.backend_data(bus_data),.backend_select(bus_select),
        .backend_response_valid(bus_reply),.backend_response_data(bus_reply_data));
    thunderjaws_pixel_clock pixel_clock(.clk_sys(clk_sys),.pll_reset(init_reset),.game_reset(board_reset),
        .pause(1'b0),.rom_download(rom_loading),.ce_pixel(ce_pixel));
    thunderjaws_raster raster(.clk_sys(clk_sys),.init_reset(init_reset),.ce_pixel(ce_pixel),
        .hpos(beam_h),.vpos(beam_v),.hblank(hblank),.vblank(vblank),.visible(visible),
        .line_start(line_start),.frame_zero(frame_zero),.vblank_start(vblank_start),.line_number(next_line));
    thunderjaws_inputs inputs(.p1_buttons(p1_buttons),.p2_buttons(p2_buttons),
        .p1_directions(p1_directions),.p2_directions(p2_directions),.service_test(service_test),.vblank(vblank),
        .sound_to_main_full(response_full),.main_to_sound_full(command_full),
        .port_260000(port0),.port_260010(port1),.port_260012(port2));
    thunderjaws_devices #(.RENDER_ENABLE(ENABLE_MOTION ? 2 : 1),.SNAPSHOT_ENABLE(SNAPSHOT_ACTIVE)) devices(.clk_sys(clk_sys),.init_reset(init_reset),.device_reset(board_reset),
        .video_snapshot_start(snapshot_start),.video_snapshot_initialized(snapshot_initialized),.video_snapshot_fault(snapshot_fault),
        .request_valid(bus_valid),.request_ready(bus_ready),.request_address(bus_address),.request_read(bus_read),
        .request_lanes(bus_lanes),.request_data(bus_data),.request_select(bus_select),.response_valid(bus_reply),.response_data(bus_reply_data),
        .rom_valid(cpu_rom_valid),.rom_ready(cpu_rom_ready),.rom_response_valid(cpu_rom_response_valid),.rom_response_data(cpu_rom_response_data),
        .port_260000(port0),.port_260010(port1),.port_260012(port2),.sound_response(response_data),
        .extra_reset_hold(extra_hold),.alpha_bank(alpha_bank),.watchdog_kick(watchdog_kick),
        .sound_reset_request(sound_reset),.sound_command_write(sound_command),.sound_command_data(command_data),.sound_response_ack(sound_ack),
        .vpos(beam_v),.eof_start(frame_zero),.ls_valid(1'b0),.ls_data(16'd0),
        .pf1_xscroll(pf1_x),.pf1_yscroll(pf1_y),.pf2_xscroll(pf2_x),.pf2_yscroll(pf2_y),
        .mo_xscroll(mo_x),.mo_yscroll(mo_y),
        .irq_arm(irq_arm),.irq_ack(irq_ack),.irq_word(irq_word),.irq_previous_word(irq_previous),
        .eeprom_restore(eeprom_restore),.eeprom_load_we(eeprom_load_we),.eeprom_load_address(eeprom_load_address),
        .eeprom_load_data(eeprom_load_data),.eeprom_dump_address(eeprom_dump_address),.eeprom_dump_data(eeprom_dump_data),.eeprom_modified(eeprom_modified),
        .pf1_fetch(p1_fetch),.pf2_fetch(p2_fetch),.alpha_fetch(alpha_fetch),
        .pf1_address(p1_code_a),.pf2_address(p2_code_a),.alpha_address(alpha_a),
        .pf1_code(p1_code),.pf1_attr(p1_attr),.pf2_code(p2_code),.pf2_attr(p2_attr),.alpha_data(alpha_data),.video_memory_late(memory_late),
        .palette_render_address(palette_address),.palette_render_data(palette_data),
        .mo_valid(mo_request),.mo_ready(mo_ready),.mo_address(mo_address),
        .mo_response_valid(mo_reply),.mo_response_data(mo_data),
        .score_valid(score_ram_valid),.score_ready(score_ram_ready),.score_address(score_ram_address),.score_read(score_ram_read),
        .score_lanes(score_ram_lanes),.score_data(score_ram_data),.score_response_valid(score_ram_reply),.score_response_data(score_ram_reply_data));
    thunderjaws_score_ram score_port(.clk_sys(clk_sys),.init_reset(init_reset),.game_reset(cpu_reset),.paused(paused),
        .score_read(score_read),.score_write(score_write),.score_address(score_address),.score_write_data(score_write_data),
        .score_read_data(score_read_data),.data_ready(score_data_ready),.feature_error(score_error),.busy(score_busy),
        .request_valid(score_ram_valid),.request_ready(score_ram_ready),.request_address(score_ram_address),.request_read(score_ram_read),
        .request_lanes(score_ram_lanes),.request_data(score_ram_data),.response_valid(score_ram_reply),.response_data(score_ram_reply_data),
        .cpu_write(bus_valid && bus_ready && bus_select[14] && !bus_read),.cpu_address(bus_address[15:1]),
        .cpu_lanes(bus_lanes),.cpu_data(bus_data),.signature_ready(score_signature_ready));
    thunderjaws_scanline_irq #(.PIXEL_DIVIDER(6)) scanline_irq(.clk_sys(clk_sys),.init_reset(init_reset || board_reset),
        .ce_pixel(ce_pixel),.hpos(beam_h),.vpos(beam_v),.arm_write(irq_arm),.arm_word(irq_word),
        .previous_word(irq_previous),.ack_write(irq_ack),.irq_level(irq4));
    thunderjaws_watchdog watchdog(.clk_sys(clk_sys),.reset(init_reset || board_reset),.pause(paused),
        .service(watchdog_kick),.expired(watchdog_expired));
    thunderjaws_background background(.clk_sys(clk_sys),.reset(render_reset),.flip_screen(flip_screen),.ce_pixel(ce_pixel),
        .hpos(beam_h),.vpos(beam_v),.next_line(next_line),.pf1_xscroll(SNAPSHOT_ACTIVE ? view_p1x : pf1_x),.pf1_yscroll(SNAPSHOT_ACTIVE ? view_p1y : pf1_y),
        .pf2_xscroll(SNAPSHOT_ACTIVE ? view_p2x : pf2_x),.pf2_yscroll(SNAPSHOT_ACTIVE ? view_p2y : pf2_y),.alpha_bank(SNAPSHOT_ACTIVE ? view_alpha_bank : alpha_bank),
        .pf1_code_address(p1_code_a),.pf1_attr_address(p1_attr_a),.pf2_code_address(p2_code_a),.pf2_attr_address(p2_attr_a),.alpha_address(alpha_a),
        .pf1_code_data(p1_code),.pf1_attr_data(p1_attr),.pf2_code_data(p2_code),.pf2_attr_data(p2_attr),.alpha_data(alpha_data),
        .pf1_rom_fetch(pf1_rom_fetch),.pf2_rom_fetch(pf2_rom_fetch),.pf1_rom_address(pf1_rom_address),.pf2_rom_address(pf2_rom_address),
        .pf1_rom_data(pf1_rom_data),.pf2_rom_data(pf2_rom_data),.pf1_rom_valid(pf1_rom_valid),.pf2_rom_valid(pf2_rom_valid),
        .pf1_rom_late(p1_rom_late),.pf2_rom_late(p2_rom_late),
        .pf1_vram_fetch(p1_fetch),.pf2_vram_fetch(p2_fetch),.alpha_vram_fetch(alpha_fetch),
        .alpha_rom_address(alpha_rom_address),.alpha_rom_data(alpha_rom_data),.composed_palette(background_palette),
        .background_pixel(background_pixel),.alpha_pixel(alpha_pixel));
    batman_dac #(.BLACK_CLAMP(0)) dac(.colour(palette_data),.red(red),.green(green),.blue(blue));
    reg [2:0] ce_pipe;
    reg [8:0] h0,h1,h2,v0,v1,v2;
    reg d0,d1,d2;
    always @(posedge clk_sys)begin
        if(init_reset)begin
            ce_pipe<=0;video_ce<=0;palette_address<=0;video_de<=0;
            video_r<=0;video_g<=0;video_b<=0;video_h<=0;video_v<=240;
            h0<=0;h1<=0;h2<=0;v0<=240;v1<=240;v2<=240;d0<=0;d1<=0;d2<=0;
            audio_l<=0;audio_r<=0;
        end else begin
            ce_pipe<={ce_pipe[1:0],ce_pixel};video_ce<=ce_pipe[2];
            if(ce_pixel)begin h0<=beam_h;v0<=beam_v;d0<=visible;end
            if(ce_pipe[0])begin palette_address<=mixed_palette;h1<=h0;v1<=v0;d1<=d0;end
            if(ce_pipe[1])begin h2<=h1;v2<=v1;d2<=d1;end
            if(ce_pipe[2])begin
                video_h<=h2;video_v<=v2;video_de<=d2;
                video_r<=d2 ? red : 0;video_g<=d2 ? green : 0;video_b<=d2 ? blue : 0;
            end
            audio_l<=audio_mix;audio_r<=audio_mix;
        end
    end
    generate if(ENABLE_MOTION!=0)begin:g_motion
        reg pending;
        wire read_request,write_enable,mob_busy;
        wire [9:0] write_address;
        wire [10:0] write_data;
        assign mo_request=read_request && !pending;
        always @(posedge clk_sys)begin
            if(init_reset)pending<=0;
            else begin
                if(mo_request && mo_ready)pending<=1;
                if(mo_reply)pending<=0;
            end
        end
        thunderjaws_mob mob(.clk(clk_sys),.reset(render_reset),.flip_screen(flip_screen),.line_start(ce_pixel && beam_h==0),.vline(next_line),
            .xscroll(SNAPSHOT_ACTIVE ? view_mox : mo_x),.yscroll(SNAPSHOT_ACTIVE ? view_moy : mo_y),.base_mo(15'h3000),.base_slip(15'h47c0),
            .vram_a(mo_address),.vram_rd(read_request),.vram_ack(mo_reply),.vram_q(mo_data),
            .rom_fetch(mo_rom_fetch),.rom_addr(mo_rom_address),.rom_group(mo_rom_data),.rom_valid(mo_rom_valid),
            .lb_we(write_enable),.lb_a(write_address),.lb_d(write_data),.busy(mob_busy),.budget_hit(mo_budget),.line_over(mo_over));
        reg was_busy;
        always @(posedge clk_sys)if(init_reset || rom_loading)was_busy<=0;else was_busy<=mob_busy;
        wire scan_enable,flipped_stain,mask_fault;
        wire [9:0] scan_address;wire [10:0] scan_data;
        assign stain_fault=mask_fault || (scan_enable && (write_enable || (ce_pixel && beam_h==0)));
        thunderjaws_stain_line stain_mask(.clk_sys(clk_sys),.reset(init_reset || rom_loading),
            .start(flip_screen && was_busy && !mob_busy && next_line<240),.line_number(next_line),
            .scan_data(scan_data),.scan_enable(scan_enable),.scan_address(scan_address),
            .display_tick(flip_screen && ce_pipe[0] && d0),.display_h(h0),.display_v(v0),.stain(flipped_stain),.fault(mask_fault));
        thunderjaws_lb line_buffer(.clk(clk_sys),.reset(init_reset || rom_loading),.wbank(next_line[0]),
            .scan_enable(scan_enable),.scan_address(scan_address),.scan_q(scan_data),
            .we(write_enable),.wa(write_address),.wd(write_data),.rd_ce(ce_pixel && visible),
            .ra({1'b0,beam_h}),.q(motion_pixel));
        thunderjaws_priority priority_mix(.clk_sys(clk_sys),.reset(init_reset),.advance(ce_pipe[0]),
            .stain_override_enable(flip_screen),.stain_override(flipped_stain),
            .hpos(h0),.background(background_pixel),.alpha(alpha_pixel),.motion(motion_pixel),.palette(mixed_palette));
    end else begin:g_no_motion
        assign mo_request=0;assign mo_address=0;assign mo_over=0;assign mo_budget=0;assign stain_fault=0;
        assign mo_rom_fetch=0;assign mo_rom_address=0;assign motion_pixel=0;
        assign mixed_palette={1'b0,background_palette};
    end endgenerate
    generate if(ENABLE_SOUND!=0)begin:g_sound
        thunderjaws_sound sound(.clk_sys(clk_sys),.init_reset(init_reset || rom_loading),
            .pause(paused),
            .sound_reset_request(sound_reset || board_reset),.sound_command_write(sound_command),
            .sound_command_data(command_data),.sound_response_ack(sound_ack),.self_test(service_test),.coin(coin),
            .sound_rom_wr(sound_rom_wr),.sound_rom_addr(sound_rom_address),.sound_rom_data(sound_rom_data),
            .oki_rom_ack(oki_rom_ack),.oki_rom_data(oki_rom_data),.oki_rom_req(oki_rom_req),.oki_rom_addr(oki_rom_address),
            .main_response_data(response_data),.main_response_ready(response_full),.main_irq6(irq6),
            .ym_audio_ch1(ym1),.ym_audio_ch2(ym2),.oki_audio(oki),.command_pending_debug(command_full));
    end else begin:g_no_sound
        assign response_data=0;assign response_full=0;assign command_full=0;assign irq6=0;
        assign ym1=0;assign ym2=0;assign oki=0;assign oki_rom_req=0;assign oki_rom_address=0;
    end endgenerate
endmodule
