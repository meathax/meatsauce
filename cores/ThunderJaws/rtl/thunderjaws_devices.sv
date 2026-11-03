// SPDX-License-Identifier: GPL-3.0-or-later
// Production device interconnect extracted from the native CPU-pair fixture.
// Input is the arbiter's held descriptor, with at most one outstanding reply.
// Shared SRAM stays inside cpu_pair. ROM is an explicit held valid/ready client;
// its address/lanes are the same held input tuple, and CPU owner stays upstream.
// All ports are synchronous clk_sys; no generated clock or timing cut is used.
module thunderjaws_devices #(parameter integer RENDER_ENABLE=0,SNAPSHOT_ENABLE=0) (
    input wire clk_sys,init_reset,device_reset,
    input wire video_snapshot_start,
    output wire video_snapshot_initialized,video_snapshot_fault,
    input wire request_valid,
    output reg request_ready,
    input wire [23:1] request_address,
    input wire request_read,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    input wire [14:0] request_select,
    output wire response_valid,
    output wire [15:0] response_data,
    output wire rom_valid,
    input wire rom_ready,rom_response_valid,
    input wire [15:0] rom_response_data,
    input wire [15:0] port_260000,port_260010,port_260012,
    input wire [7:0] sound_response,
    output wire extra_reset_hold,
    output wire [2:0] alpha_bank,
    output wire watchdog_kick,sound_reset_request,sound_command_write,
    output wire [7:0] sound_command_data,
    output wire sound_response_ack,
    input wire [8:0] vpos,
    input wire eof_start,ls_valid,
    input wire [15:0] ls_data,
    output wire ls_ready,
    output wire [15:0] vad_option,
    output wire [8:0] mo_xscroll,mo_yscroll,pf1_xscroll,pf1_yscroll,pf2_xscroll,pf2_yscroll,
    output wire palette_bank,
    output wire irq_arm,irq_ack,
    output wire [15:0] irq_word,irq_previous_word,
    input wire eeprom_restore,eeprom_load_we,
    input wire [10:0] eeprom_load_address,eeprom_dump_address,
    input wire [7:0] eeprom_load_data,
    output wire [7:0] eeprom_dump_data,
    output wire eeprom_modified,
    input wire pf1_fetch,pf2_fetch,alpha_fetch,
    input wire [14:0] pf1_address,pf2_address,alpha_address,
    output wire [15:0] pf1_code,pf1_attr,pf2_code,pf2_attr,alpha_data,
    output wire [2:0] video_memory_late,
    input wire [10:0] palette_render_address,
    output wire [15:0] palette_render_data,
    input wire mo_valid,
    output wire mo_ready,
    input wire [14:0] mo_address,
    output wire mo_response_valid,
    output wire [63:0] mo_response_data,
    input wire score_valid,
    output wire score_ready,
    input wire [14:0] score_address,
    input wire score_read,
    input wire [1:0] score_lanes,
    input wire [15:0] score_data,
    output wire score_response_valid,
    output wire [15:0] score_response_data
);
    wire accept=request_valid && request_ready;
    wire eeprom_selected=request_select[2] || request_select[3];
    wire simple_selected=!(request_select[0] || request_select[1] ||
        eeprom_selected || request_select[12] || request_select[14]);
    wire eeprom_ready,palette_ready,vram_ready;
    wire vram_snapshot_initialized,vram_snapshot_fault,palette_snapshot_initialized,palette_snapshot_fault;
    assign video_snapshot_initialized=vram_snapshot_initialized && palette_snapshot_initialized;
    assign video_snapshot_fault=vram_snapshot_fault || palette_snapshot_fault;
    wire eeprom_reply,palette_reply,vram_reply;
    wire [15:0] eeprom_data,palette_data,vram_data,io_data,vad_data;
    reg simple_reply;
    reg [15:0] simple_data;
    wire [7:0] attr_msb,attr_lsb;
    wire eof_req,eof_ack,aux_valid,aux_ready,aux_reply;
    wire [5:0] eof_index;
    wire [14:0] aux_address;
    wire [15:0] eof_data,aux_data;
    wire ram_valid=score_valid || (request_valid && request_select[14]);
    wire [14:0] ram_address=score_valid ? score_address : request_address[15:1];
    wire ram_read=score_valid ? score_read : request_read;
    wire [1:0] ram_lanes=score_valid ? score_lanes : request_lanes;
    wire [15:0] ram_data=score_valid ? score_data : request_data;
    wire ram_ready,ram_reply;wire [15:0] ram_reply_data;
    reg ram_reply_is_score;
    always @(posedge clk_sys)begin
        if(init_reset)ram_reply_is_score<=0;
        else if(ram_valid && ram_ready)ram_reply_is_score<=score_valid;
    end
    assign vram_ready=ram_ready && !score_valid;
    assign score_ready=ram_ready;
    assign vram_reply=ram_reply && !ram_reply_is_score;
    assign vram_data=ram_reply_data;
    assign score_response_valid=ram_reply && ram_reply_is_score;
    assign score_response_data=ram_reply_data;

    assign rom_valid=!init_reset && request_valid && request_select[0];
    always @* begin
        request_ready=1'b0;
        if(!init_reset)begin
            if(request_select[0])request_ready=rom_ready;
            else if(request_select[1])request_ready=1'b0; // not an external device
            else if(eeprom_selected)request_ready=eeprom_ready;
            else if(request_select[12])request_ready=palette_ready;
            else if(request_select[14])request_ready=vram_ready;
            else request_ready=1'b1;
        end
    end
    assign response_valid=!init_reset &&
        (rom_response_valid || eeprom_reply || palette_reply || vram_reply || simple_reply);
    assign response_data=rom_response_valid ? rom_response_data :
        eeprom_reply ? eeprom_data : palette_reply ? palette_data :
        vram_reply ? vram_data : simple_data;
    always @(posedge clk_sys)begin
        simple_reply<=!init_reset && accept && simple_selected;
        if(init_reset)simple_data<=0;
        else if(accept && simple_selected)
            simple_data<=request_select[13] ? vad_data : io_data;
    end

    thunderjaws_io io(.clk_sys(clk_sys),.init_reset(init_reset),
        .commit(accept && simple_selected),.request_read(request_read),
        .request_select(request_select),.request_lanes(request_lanes),.request_data(request_data),
        .port_260000(port_260000),.port_260010(port_260010),.port_260012(port_260012),
        .sound_response(sound_response),.read_data(io_data),.extra_reset_hold(extra_reset_hold),
        .alpha_bank(alpha_bank),.watchdog_kick(watchdog_kick),
        .sound_reset_request(sound_reset_request),.sound_command_write(sound_command_write),
        .sound_command_data(sound_command_data),.sound_response_ack(sound_response_ack));

    thunderjaws_eeprom eeprom(.clk_sys(clk_sys),.init_reset(init_reset),
        .game_reset(device_reset),.restore_active(eeprom_restore),
        .request_valid(request_valid && eeprom_selected),.request_ready(eeprom_ready),
        .request_unlock(request_select[3]),.request_read(request_read),
        .word_address(request_address[11:1]),.request_lanes(request_lanes),.request_data(request_data),
        .response_valid(eeprom_reply),.response_data(eeprom_data),.write_accepted(eeprom_modified),
        .load_we(eeprom_load_we),.load_address(eeprom_load_address),.load_data(eeprom_load_data),
        .dump_address(eeprom_dump_address),.dump_data(eeprom_dump_data));

    thunderjaws_vad_regs vad(.clk(clk_sys),.init_reset(init_reset),.reset(device_reset),
        .cpu_cs(accept && request_select[13]),.cpu_we(!request_read),
        .cpu_a(request_address[5:1]),.cpu_din(request_data),.cpu_lanes(request_lanes),.cpu_dout(vad_data),
        .vpos(vpos),.eof_start(eof_start),.eof_req(eof_req),.eof_idx(eof_index),
        .eof_data(eof_data),.eof_ack(eof_ack),.ls_wr(ls_valid),.ls_d(ls_data),.ls_ready(ls_ready),
        .reg_opt(vad_option),.attr_msb_latch(attr_msb),.attr_lsb_latch(attr_lsb),
        .mo_xscroll(mo_xscroll),.mo_yscroll(mo_yscroll),
        .playfield_xscroll(pf1_xscroll),.playfield_yscroll(pf1_yscroll),
        .playfield2_xscroll(pf2_xscroll),.playfield2_yscroll(pf2_yscroll),
        .palette_bank(palette_bank),.reg_vint(irq_previous_word),
        .irq_arm(irq_arm),.irq_ack(irq_ack),.irq_word(irq_word));

    thunderjaws_eof_bridge eof_bridge(.clk_sys(clk_sys),.init_reset(init_reset),
        .eof_req(eof_req),.eof_index(eof_index),.eof_ack(eof_ack),.eof_data(eof_data),
        .aux_valid(aux_valid),.aux_ready(aux_ready),.aux_address(aux_address),
        .aux_response_valid(aux_reply),.aux_response_data(aux_data));

    generate if(RENDER_ENABLE==0)begin:g_cpu_only
    assign vram_snapshot_initialized=!init_reset;assign vram_snapshot_fault=0;
    assign pf1_code=0;assign pf1_attr=0;assign pf2_code=0;assign pf2_attr=0;assign alpha_data=0;
    assign video_memory_late=0;
    assign mo_ready=0;assign mo_response_valid=0;assign mo_response_data=0;
    thunderjaws_video_ram video_ram(.clk_sys(clk_sys),.init_reset(init_reset),
        .request_valid(ram_valid),.request_ready(ram_ready),
        .word_address(ram_address),.request_read(ram_read),
        .request_lanes(ram_lanes),.request_data(ram_data),
        .attribute_enable(vad_option[7] && !score_valid),.attribute_msb(attr_msb),.attribute_lsb(attr_lsb),
        .response_valid(ram_reply),.response_data(ram_reply_data),
        .aux_valid(aux_valid),.aux_ready(aux_ready),.aux_address(aux_address),
        .aux_response_valid(aux_reply),.aux_response_data(aux_data));
    end else begin:g_render
    thunderjaws_video_ports #(.PACKED_ENABLE(RENDER_ENABLE==2),.SNAPSHOT_ENABLE(SNAPSHOT_ENABLE)) video_ports(.clk_sys(clk_sys),.init_reset(init_reset),
        .snapshot_start(video_snapshot_start),.snapshot_initialized(vram_snapshot_initialized),.snapshot_fault(vram_snapshot_fault),
        .cpu_valid(ram_valid),.cpu_ready(ram_ready),
        .cpu_address(ram_address),.cpu_read(ram_read),.cpu_lanes(ram_lanes),.cpu_data(ram_data),
        .attribute_enable(vad_option[7] && !score_valid),.attribute_msb(attr_msb),.attribute_lsb(attr_lsb),
        .cpu_response_valid(ram_reply),.cpu_response_data(ram_reply_data),
        .eof_valid(aux_valid),.eof_ready(aux_ready),.eof_address(aux_address),
        .eof_response_valid(aux_reply),.eof_response_data(aux_data),
        .pf1_fetch(pf1_fetch),.pf2_fetch(pf2_fetch),.alpha_fetch(alpha_fetch),
        .pf1_address(pf1_address),.pf2_address(pf2_address),.alpha_address(alpha_address),
        .pf1_code(pf1_code),.pf1_attr(pf1_attr),.pf2_code(pf2_code),.pf2_attr(pf2_attr),.alpha_data(alpha_data),
        .late(video_memory_late),.mo_valid(mo_valid),.mo_ready(mo_ready),.mo_address(mo_address),
        .mo_response_valid(mo_response_valid),.mo_response_data(mo_response_data));
    end endgenerate

    thunderjaws_palette_ram #(.SNAPSHOT_ENABLE(SNAPSHOT_ENABLE)) palette_ram(.clk_sys(clk_sys),.init_reset(init_reset),
        .snapshot_start(video_snapshot_start),.snapshot_initialized(palette_snapshot_initialized),.snapshot_fault(palette_snapshot_fault),
        .request_valid(request_valid && request_select[12]),.request_ready(palette_ready),
        .word_address(request_address[11:1]),.request_read(request_read),
        .request_lanes(request_lanes),.request_data(request_data),
        .response_valid(palette_reply),.response_data(palette_data),
        .render_address(palette_render_address),.render_data(palette_render_data));
endmodule
