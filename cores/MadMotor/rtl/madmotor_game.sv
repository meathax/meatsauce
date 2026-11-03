// SPDX-License-Identifier: GPL-3.0-or-later
// Running Mad Motor CPU, native RAM and donor graphics. ROM ports are held
// requests: data/ready must stay valid until the corresponding cs is released.
module madmotor_game #(
    parameter integer SYS_HZ=48000000
) (
    input logic bandit,
    input tri0 [31:0] joystick_0,joystick_1,
    input tri0 [15:0] right_stick_0,right_stick_1,
    output wire [23:0] rgb24,

    input logic clk, reset, pause,
    input logic [15:0] controls, dips,
    input logic [2:0] coins_n,
    input logic audio_load_we,
    input logic [1:0] audio_load_region,
    input logic [17:0] audio_load_addr,
    input logic [7:0] audio_load_data,
    input logic mcu_rom_we,
    input logic [11:0] mcu_rom_addr,
    input logic [7:0] mcu_rom_data,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample_ce,audio_clipped,
    output wire [20:0] debug_sound_address,
    output wire [7:0] debug_sound_data,
    output wire debug_sound_write,
    output wire main_cs,
    output wire [17:0] main_addr,
    input logic [15:0] main_data,
    input logic main_ok,
    output wire [16:0] tile_addr [3],
    output wire [2:0] tile_cs,
    input logic [31:0] tile_data [3],
    input logic [2:0] tile_ok,
    output wire [17:0] sprite_addr,
    output wire sprite_cs,
    input logic [31:0] sprite_data,
    input logic sprite_ok,
    output wire [3:0] red, green, blue,
    output wire hs, vs, hblank, vblank, pixel_valid,
    output wire [8:0] pixel_x, pixel_y,
    output wire [7:0] sound_latch,
    output wire sound_irq,
    output wire halted,
    output wire [23:0] debug_address,
    output wire debug_request, debug_read, debug_write,
    output wire [15:0] debug_write_data,
    output wire [15:0] debug_read_data,
    output wire [1:0] debug_byte_enable
`ifdef VERILATOR
    ,output wire [11:0] debug_cpu_credit,
    output wire [31:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped,
    output wire debug_mcu_irq5,debug_mcu_cen,
    output wire [31:0] debug_video_planes,
    output wire [9:0] debug_video_palette_index,
    output wire [15:0] debug_priority_word
`endif
);
    localparam integer PIXEL_DIV=SYS_HZ/6000000;
    localparam integer PIXEL_PHASE_WIDTH=$clog2(PIXEL_DIV);
    logic [PIXEL_PHASE_WIDTH-1:0] pixel_phase=0;
    wire ce_pix=pixel_phase==0;
    // Integer root/6MHz candidate profile. Raster is inherited from the
    // BAC06 donor; measured Mad Motor PCB clock qualification remains open.
    // Soft reset must not freeze the divider at its enabled phase and turn
    // a 6MHz pixel stream into a root-rate burst. The oscillator is continuous.
    always_ff @(posedge clk)
        pixel_phase<=pixel_phase==PIXEL_PHASE_WIDTH'(PIXEL_DIV-1)?
                     {PIXEL_PHASE_WIDTH{1'b0}}:pixel_phase+1'b1;
    wire phi1,phi2,cpu_bus_wait;
    wire [11:0] cpu_credit;
    madmotor_cpu_ce #(.NOMINAL_DIV(SYS_HZ/12000000),.BANDIT_DIV(SYS_HZ/10000000)) cpu_clock(
        .bandit(bandit),.clk(clk),.reset(reset),.pause(pause),.block_phi2(cpu_bus_wait),
        .phi1(phi1),.phi2(phi2),.credit(cpu_credit)
`ifdef VERILATOR
        ,.debug_ticks(debug_cpu_ticks),.debug_pairs(debug_cpu_pairs),.debug_dropped(debug_cpu_dropped)
`endif
    );
`ifdef VERILATOR
    assign debug_cpu_credit=cpu_credit;
`endif
    wire [23:0] address;
    wire [15:0] write_data;
    wire [1:0] be;
    wire reading, request, write_strobe;
    wire work_cs, object_cs, palette_cs, aux_cs;
    wire [2:0] pf_cs,ctrl_cs,scroll_cs;
    logic [15:0] read_data;
    logic request_q, vblank_q;
    wire irq_tick=vblank && !vblank_q;
    always_ff @(posedge clk) begin
        if(reset) begin request_q<=0;vblank_q<=1;end
        else begin request_q<=request;vblank_q<=vblank;end
    end
    function automatic [7:0] decode(input [7:0] raw);
        decode={raw[0],raw[6],raw[2],raw[4],raw[3],raw[5],raw[1],raw[7]};
    endfunction
    wire [15:0] decoded_rom={decode(main_data[15:8]),decode(main_data[7:0])};
    wire sprite_dma_busy;
    wire ready=!sprite_dma_busy && (main_cs?main_ok:request_q);
    assign main_addr=address[18:1];
    assign debug_address=address;
    assign debug_request=request;
    assign debug_read=reading;
    assign debug_write=write_strobe;
    assign debug_write_data=write_data;
    assign debug_read_data=read_data;
    assign debug_byte_enable=be;
    wire [15:0] bandit_players;
    wire [7:0] bandit_system,track_data;
    wire mcu_irq5,mcu_cen;
    wire [15:0] mcu_response;
    bandit_mcu #(.SYS_HZ(SYS_HZ)) mcu(
        .clk(clk),.reset(reset),.pause(pause),.run_enable(bandit),
        .command_we(bandit && write_strobe && address==24'h30c016),
        .command_reset(bandit && write_strobe && address==24'h30c01e),
        .command_data(write_data),.rom_load_we(mcu_rom_we),
        .rom_load_addr(mcu_rom_addr),.rom_load_data(mcu_rom_data),
        .irq5(mcu_irq5),.mcu_cen(mcu_cen),.response(mcu_response));
`ifdef VERILATOR
    assign debug_mcu_irq5=mcu_irq5;
    assign debug_mcu_cen=mcu_cen;
`endif
    reg [15:0] priority_word;
    always @(posedge clk) begin
        if(reset) priority_word<=0;
        else if(bandit && write_strobe && address==24'h30c010) begin
            if(be[0]) priority_word[7:0]<=write_data[7:0];
            if(be[1]) priority_word[15:8]<=write_data[15:8];
        end
    end
    bandit_controls bandit_input(
        .clk(clk),.reset(reset),.pause(pause),.frame_tick(irq_tick),.analog_mode(!dips[0]),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .right_stick_0(right_stick_0),.right_stick_1(right_stick_1),.vblank(vblank),
        .bus_read(bandit && request && reading && !request_q),.bus_write(bandit && write_strobe),
        .bus_address(address),.bus_be(be),.player_port(bandit_players),.system_port(bandit_system),
        .pause_button(),.track_data(track_data));
    madmotor_main main (
        .bandit(bandit),
        .clk(clk), .reset(reset), .en_phi1(phi1), .en_phi2(phi2), .vblank_irq(irq_tick),.mcu_irq5(mcu_irq5),
        .controls(bandit?bandit_players:controls), .dips(dips), .system_port(bandit?{8'd0,bandit_system}:{8'd0,4'hf,vblank,coins_n}),
        .address(address), .write_data(write_data), .byte_enable(be),
        .read_cycle(reading), .request(request), .read_data(read_data), .ready(ready),
        .rom_cs(main_cs), .work_cs(work_cs), .sprite_cs(object_cs), .palette_cs(palette_cs),
        .tile_cs(pf_cs), .control_cs(ctrl_cs), .scroll_cs(scroll_cs), .aux_cs(aux_cs),
        .write_strobe(write_strobe), .sound_latch(sound_latch), .sound_irq(sound_irq),
        .irq_ack(), .halted(halted), .function_code(),.bus_wait(cpu_bus_wait),
        .service_br_n(1'b1),.service_bgack_n(1'b1),
        .service_bg_n(),.service_as_n(),.service_dtack_n()
    );
    wire [15:0] work_q,pf_q [3],aux_q;
    wire [12:0] vram_addr [3];
    wire [2:0] vram_cs;
    wire [15:0] vram_data [3];
    wire [15:0] palette_q, object_q;
    wire [7:0] plane_pixel [4];
`ifdef VERILATOR
    wire [31:0] video_planes_internal;
    wire [9:0] video_palette_index_internal;
    assign debug_video_planes=video_planes_internal;
    assign debug_video_palette_index=video_palette_index_internal;
    assign debug_priority_word=priority_word;
`endif
    wire [8:0] raw_x,raw_y;
    madmotor_memory memory(
        .bandit(bandit),
        .clk(clk),.address(address),.write_data(write_data),.be(be),.write_strobe(write_strobe),
        .work_cs(work_cs),.aux_cs(aux_cs),.pf_cs(pf_cs),.work_q(work_q),.aux_q(aux_q),.pf_q(pf_q),
        .vram_addr(vram_addr),.vram_data(vram_data),
        .service_addr(13'd0),.service_data(16'd0),.service_we(2'b00),.service_q());
    always_comb begin
        read_data=16'hffff;
        if(main_cs)read_data=bandit?main_data:decoded_rom;
        else if(bandit && address[23:4]==20'h30001)read_data={8'hff,track_data};
        else if(work_cs)read_data=work_q;
        else if(palette_cs)read_data=palette_q;
        else if(object_cs)read_data=object_q;
        else if(pf_cs[0])read_data=pf_q[0];
        else if(pf_cs[1])read_data=pf_q[1];
        else if(pf_cs[2])read_data=pf_q[2];
        else if(aux_cs)read_data=aux_q;
    end
    madmotor_video video (
        .bandit(bandit),.palette_ext(bandit && address[14]),.priority_word(priority_word),
        .sprite_dma(bandit && write_strobe && address==24'h30c012),
        .sprite_dma_busy(sprite_dma_busy),.rgb24(rgb24),
        .clk(clk), .reset(reset), .chip_cen(1'b1), .ce_pix(ce_pix),
        .cpu_we(write_strobe), .cpu_ctrl_cs(ctrl_cs|scroll_cs), .cpu_obj_cs(object_cs), .cpu_pal_cs(palette_cs),
        .cpu_addr(address[12:1]), .cpu_data(write_data), .cpu_be(be),
        .cpu_pal_data(palette_q), .cpu_obj_data(object_q),
        .vram_addr(vram_addr), .vram_cs(vram_cs), .vram_data(vram_data), .vram_ok(3'b111),
        .tile_addr(tile_addr), .tile_cs(tile_cs), .tile_data(tile_data), .tile_ok(tile_ok),
        .sprite_addr(sprite_addr), .sprite_cs(sprite_cs), .sprite_data(sprite_data), .sprite_ok(sprite_ok),
        .red(red), .green(green), .blue(blue), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
        .pixel_valid(pixel_valid), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .plane_pixel(plane_pixel), .raw_x(raw_x), .raw_y(raw_y)
`ifdef VERILATOR
        ,.debug_video_planes(video_planes_internal),.debug_video_palette_index(video_palette_index_internal)
`endif
    );
    madmotor_audio #(.SYS_HZ(SYS_HZ)) audio(
        .bandit(bandit),
        .clk(clk),.reset(reset),.command(sound_latch),.command_irq(sound_irq),
        .load_we(audio_load_we),.load_region(audio_load_region),.load_addr(audio_load_addr),.load_data(audio_load_data),
        .audio_left(audio_left),.audio_right(audio_right),.sample_ce(audio_sample_ce),.clipped(audio_clipped),
        .debug_rom_addr(),.debug_rom_cs(),.debug_ram_data(),.debug_ram_addr(),.debug_ram_we(),
        .debug_chip_address(debug_sound_address),.debug_chip_data(debug_sound_data),.debug_chip_write(debug_sound_write)
    );
endmodule
