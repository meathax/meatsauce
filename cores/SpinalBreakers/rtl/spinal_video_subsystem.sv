// SPDX-License-Identifier: GPL-3.0-or-later
// CPU-visible board RAM, graphics-ROM request bridge and continuous scanout.
// Frame-coherent video state and physical SDRAM service are separate clients.
module spinal_video_subsystem(
    input logic clk,bus_reset,cold_reset,game_reset,
    input logic [23:0] cpu_address,
    input logic cpu_as_n,cpu_uds_n,cpu_lds_n,cpu_read,
    input logic [2:0] cpu_fc,
    input logic [15:0] cpu_out,
    input logic score_request,score_paused,score_write,input logic [13:0] score_address,input logic [7:0] score_data_in,
    output wire score_ready,output wire [7:0] score_data_out,
    output wire [15:0] cpu_in,
    output wire cpu_dtack_n,cpu_vpa_n,
    output wire main_rom_request,
    output wire [17:1] main_rom_address,
    input logic main_rom_ready,
    input logic [15:0] main_rom_data,
    input logic [15:0] in0,in1,dips,
    output wire [7:0] sound_command,
    output wire sound_write,flip_screen,
    output wire [7:0] gfxbank,
    output wire [15:0] scrollx1,
    output wire [3:0] gga_index,
    output wire [7:0] gga_data,
    output wire gga_write,
    output wire video_rom_request,
    output wire [3:0] video_rom_space,
    output wire [21:0] video_rom_address,
    input logic video_rom_ready,
    input logic [63:0] video_rom_data,
    output wire ce_pixel,hs,vs,de,
    output wire [4:0] red,green,blue,
    output wire [8:0] pixel_x,pixel_y,
    output wire pixel_valid,
    output wire [31:0] underruns,
    output wire render_urgent,
    output wire raw_vblank_start
);
    wire [10:0] va;
    wire [9:0] sa,pa;
    wire [7:0] ra;
    wire [15:0] v0,v1,row,palette,live_row;
    logic [7:0] frame_gfxbank;
    logic [15:0] frame_scrollx1;
    logic scroll_copy=0,scroll_copy_valid=0;
    logic [7:0] scroll_copy_address=0,scroll_copy_pending=0;
    wire scroll_capture=raw_vblank_start && !bus_reset && !game_reset;
    wire [7:0] bus_row_address=scroll_copy ? scroll_copy_address : ra;
    // Copy at vblank and keep the display view for all 240 rows. The CPU bus
    // defers writes to this state until the copy completes, including a write
    // on the capture edge; no software write-window assumption is required.
    // One registered source read plus 256 writes; no SDRAM transaction is used.
    spinal_scroll_frame_ram scroll_frame_ram(
        .clk(clk),.write_enable(scroll_copy_valid),.write_address(scroll_copy_pending),
        .write_data(live_row),.read_address(ra),.read_data(row));
    always_ff @(posedge clk) begin
        if(bus_reset || cold_reset || game_reset) begin
            scroll_copy<=0;scroll_copy_valid<=0;scroll_copy_address<=0;
            frame_gfxbank<=0;frame_scrollx1<=0;
        end else if(scroll_capture) begin
            frame_gfxbank<=gfxbank;frame_scrollx1<=scrollx1;
            scroll_copy<=1;scroll_copy_valid<=0;scroll_copy_address<=0;
        end else begin
            scroll_copy_valid<=scroll_copy;
            scroll_copy_pending<=scroll_copy_address;
            if(scroll_copy) begin
                if(scroll_copy_address==8'hff) scroll_copy<=0;
                else scroll_copy_address<=scroll_copy_address+1'b1;
            end
        end
    end
    wire [63:0] sprite_block,video_data;
    wire video_write_commit,request,ready;
    wire [3:0] space;
    wire [21:0] video_address;
    spinal_main_bus #(.FRAME_SCROLL(1)) bus(.clk(clk),.reset(bus_reset),.address(cpu_address),.as_n(cpu_as_n),
        .video_snapshot_hold(scroll_capture || scroll_copy || scroll_copy_valid),
        .score_request(score_request),.score_paused(score_paused),.score_write(score_write),.score_address(score_address),.score_data_in(score_data_in),.score_ready(score_ready),.score_data_out(score_data_out),
        .uds_n(cpu_uds_n),.lds_n(cpu_lds_n),.read_not_write(cpu_read),.fc(cpu_fc),
        .cpu_data_out(cpu_out),.cpu_data_in(cpu_in),.dtack_n(cpu_dtack_n),.vpa_n(cpu_vpa_n),
        .rom_req(main_rom_request),.rom_address(main_rom_address),.rom_ok(main_rom_ready),.rom_data(main_rom_data),
        .in0(in0),.in1(in1),.dips(dips),.sound_command(sound_command),.sound_write(sound_write),
        .flip_screen(flip_screen),.gfxbank(gfxbank),.scrollx1(scrollx1),
        .gga_index(gga_index),.gga_data(gga_data),.gga_write(gga_write),
        .video_vram_address(va),.video_sprite_address(sa),.video_palette_address(pa),
        .video_row_address(bus_row_address),.video_vram0(v0),.video_vram1(v1),.video_sprite(),
        .video_palette(palette),.video_row(live_row),.video_sprite_block(sprite_block),.video_write_commit(video_write_commit));
    spinal_video_mem_adapter adapter(.clk(clk),.reset(bus_reset),
        .request(request && !scroll_capture && !scroll_copy && !scroll_copy_valid),.space(space),
        .address(video_address),.ready(ready),.data(video_data),.vram_address(va),.sprite_address(sa),
        .row_address(ra),.vram0(v0),.vram1(v1),.sprite_block(sprite_block),.row(row),
        .video_write_commit(video_write_commit),.video_write_address(cpu_address),
        .rom_request(video_rom_request),.rom_space(video_rom_space),.rom_address(video_rom_address),
        .rom_ready(video_rom_ready),.rom_data(video_rom_data));
    spinal_scanout scan(.clk(clk),.cold_reset(cold_reset),.game_reset(game_reset),.flip_screen(flip_screen),
        .gfxbank(frame_gfxbank),.scrollx1(frame_scrollx1),.mem_req(request),.mem_space(space),.mem_address(video_address),
        .mem_ready(ready),.mem_data(video_data),.palette_address(pa),.palette_data(palette),
        .ce_pixel(ce_pixel),.hs(hs),.vs(vs),.de(de),.red(red),.green(green),.blue(blue),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_valid(pixel_valid),.underruns(underruns),.raw_vblank_start(raw_vblank_start),.render_urgent(render_urgent));
endmodule

// Module-scope storage preserves native M10K inference in Quartus 17.
module spinal_scroll_frame_ram(
    input wire clk,write_enable,
    input wire [7:0] write_address,read_address,
    input wire [15:0] write_data,
    output logic [15:0] read_data
);
    (* ramstyle="M10K" *) logic [15:0] mem[0:255];
    always_ff @(posedge clk) begin
        if(write_enable) mem[write_address]<=write_data;
        read_data<=mem[read_address];
    end
endmodule
