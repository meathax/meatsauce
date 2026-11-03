// SPDX-License-Identifier: GPL-3.0-or-later
// Darkmist main Z80 and board map; ROM and T5182 use explicit external interfaces.
module darkmist_main (
    input  wire        clk,
    input  wire        reset,
    input  wire        cpu_cen,
    input  wire        pause,
    input  wire        scanline_tick,
    input  wire [7:0]  scanline,
    input  wire [7:0]  p1,
    input  wire [7:0]  p2,
    input  wire [7:0]  starts,
    input  wire [7:0]  dip1,
    input  wire [7:0]  dip2,
    input  wire [7:0]  unknown_inputs,
    output wire        rom_req,
    output wire [16:0] rom_addr,
    output wire        rom_opcode,
    input  wire        rom_valid,
    input  wire [7:0]  rom_data,
    output wire [6:0]  sound_host_addr,
    output wire [7:0]  sound_host_dout,
    input  wire [7:0]  sound_host_din,
    input  wire        sound_semaphore,
    output wire        sound_host_write,
    output wire        sound_irq,
    output wire        main_sem_acquire,
    output wire        main_sem_release,
    output reg  [7:0]  hardware_control,
    output reg  [7:0]  sprite_bank,
    input  wire [2:0]  video_region,
    input  wire [11:0] video_addr,
    output wire [7:0]  video_data,
    input  wire [6:0]  sprite_desc_index,
    output wire [31:0] sprite_desc_data,
    input  wire [9:0]  text_tile_index,
    output wire [15:0] text_tile_data,
    input  wire [7:0]  color_index,
    output wire [11:0] color_rgb,
    output wire [15:0] bg_scroll_x,bg_scroll_y,fg_scroll_x,fg_scroll_y,
    input wire hs_access,hs_we,
    input wire [11:0] hs_addr,
    input wire [7:0] hs_data,
    input  wire [11:0] debug_addr,
    output reg  [7:0]  debug_data,
    output wire        paused,
    output wire [15:0] cpu_addr,
    output wire [7:0]  cpu_dout,
    output wire        cpu_m1_n,
    output wire        cpu_mreq_n,
    output wire        cpu_iorq_n,
    output wire        cpu_rd_n,
    output wire        cpu_wr_n,
    output reg         trace_write,
    output reg  [15:0] trace_addr,
    output reg  [7:0]  trace_data
);
    wire cpu_rfsh_n, cpu_halt_n, cpu_busak_n;
    reg [7:0] cpu_din;
    reg irq_pending;
    reg [7:0] irq_vector;
    reg write_seen;
    reg response_ready;
    reg [7:0] response_data;
    wire memory_read = !cpu_mreq_n && !cpu_rd_n;
    wire memory_write = !cpu_mreq_n && !cpu_wr_n;
    wire write_once = memory_write && !write_seen && !reset;
    wire rom_read = memory_read && cpu_addr < 16'hc000;

    assign rom_req = rom_read && !response_ready && !reset;
    assign rom_addr = cpu_addr < 16'h8000 ? {1'b0,cpu_addr} :
                      {1'b1,1'b0,hardware_control[7],cpu_addr[13:0]};
    assign rom_opcode = cpu_addr < 16'h8000 && !cpu_m1_n;
    wire cpu_wait_n = !rom_read || response_ready;
    assign paused = pause;

    T80s cpu (
        .RESET_n(!reset), .CLK(clk), .CEN(cpu_cen && !pause),
        .WAIT_n(cpu_wait_n), .INT_n(!irq_pending), .NMI_n(1'b1),
        .BUSRQ_n(1'b1), .OUT0(1'b0), .DI(cpu_din),
        .M1_n(cpu_m1_n), .MREQ_n(cpu_mreq_n), .IORQ_n(cpu_iorq_n),
        .RD_n(cpu_rd_n), .WR_n(cpu_wr_n), .RFSH_n(cpu_rfsh_n),
        .HALT_n(cpu_halt_n), .BUSAK_n(cpu_busak_n),
        .A(cpu_addr), .DOUT(cpu_dout)
    );

    assign sound_host_addr = cpu_addr[6:0];
    assign sound_host_dout = cpu_dout;
    assign sound_host_write = write_once && cpu_addr >= 16'hd600 && cpu_addr <= 16'hd67f;
    assign sound_irq = write_once && cpu_addr == 16'hd680;
    assign main_sem_acquire = write_once && cpu_addr == 16'hd682;
    assign main_sem_release = write_once && cpu_addr == 16'hd683;

    // Synchronous CPU read port and independent renderer/debug read port.
    // Large SRAM arrays are not cleared by reset; the real program initializes them.
    reg [7:0] workram[0:4095];
    // Byte banks permit one CPU read/write port and one live descriptor port.
    // Each sprite's four descriptor bytes start at a four-byte aligned address.
    reg [7:0] spriteram0[0:1023],spriteram1[0:1023];
    reg [7:0] spriteram2[0:1023],spriteram3[0:1023];
    reg [7:0] text_code[0:1023],text_attr[0:1023];
    reg [7:0] palette_lo[0:255];
    reg [7:0] palette_hi[0:255];
    reg [7:0] scrollram[0:31];
    reg [7:0] work_read, palette_lo_read, palette_hi_read, scroll_read;
    reg [7:0] sprite_cpu0,sprite_cpu1,sprite_cpu2,sprite_cpu3;
    reg [7:0] sprite_render0,sprite_render1,sprite_render2,sprite_render3;
    reg [7:0] text_cpu_code,text_cpu_attr,text_render_code,text_render_attr;
    reg [7:0] palette_render_lo,palette_render_hi;
    reg [1:0] sprite_cpu_select,sprite_video_select;
    reg text_cpu_select,text_video_select;
    reg [2:0] video_region_q;
    // Third diagnostic read port has an identical write-broadcast replica.
    // If unconnected in production, synthesis removes these replicas.
    reg [7:0] sprite_video0[0:1023],sprite_video1[0:1023],sprite_video2[0:1023],sprite_video3[0:1023];
    reg [7:0] text_video_code[0:1023],text_video_attr[0:1023];
    reg [7:0] palette_video_lo[0:255],palette_video_hi[0:255];

    // Defined cold power-up state matches MAME 0.289 shared RAM allocation.
    // No warm reset clear: CPU writes and synchronous OLD_DATA reads stay intact.
    reg text_powerup_init_complete = 1'b0;
    integer text_powerup_index;
    initial begin
        for (text_powerup_index = 0; text_powerup_index < 1024;
             text_powerup_index = text_powerup_index + 1) begin
            text_code[text_powerup_index] = 8'h00;
            text_attr[text_powerup_index] = 8'h00;
            text_video_code[text_powerup_index] = 8'h00;
            text_video_attr[text_powerup_index] = 8'h00;
        end
        text_powerup_init_complete = 1'b1;
    end

    reg [7:0] sv0,sv1,sv2,sv3,tvc,tva,pvl,pvh,scroll_video;
    wire [7:0] sprite_read=sprite_cpu_select==0?sprite_cpu0:sprite_cpu_select==1?sprite_cpu1:sprite_cpu_select==2?sprite_cpu2:sprite_cpu3;
    wire [7:0] text_read=text_cpu_select?text_cpu_attr:text_cpu_code;
    wire [7:0] sprite_video=sprite_video_select==0?sv0:sprite_video_select==1?sv1:sprite_video_select==2?sv2:sv3;
    assign sprite_desc_data={sprite_render3,sprite_render2,sprite_render1,sprite_render0};
    assign text_tile_data={text_render_attr,text_render_code};
    assign color_rgb={palette_render_hi[3:0],palette_render_lo};
    assign video_data=video_region_q==0?sprite_video:video_region_q==1?(text_video_select?tva:tvc):video_region_q==2?scroll_video:video_region_q==3?pvl:video_region_q==4?pvh:8'hff;

    function automatic [15:0] decode_scroll(input [7:0] previous,current);
        decode_scroll={previous[3:0],previous[7:4],current[6:0],current[7]};
    endfunction
    assign bg_scroll_x=decode_scroll(scrollram[1],scrollram[2]);
    assign bg_scroll_y=decode_scroll(scrollram[5],scrollram[6]);
    assign fg_scroll_x=decode_scroll(scrollram[9],scrollram[10]);
    assign fg_scroll_y=decode_scroll(scrollram[13],scrollram[14]);

    always @(posedge clk) begin
        work_read <= workram[cpu_addr[11:0]];
        // Each bank has explicit full-byte clocked CPU and renderer outputs.
        // Selectors sample the same pre-edge addresses as the original outputs.
        sprite_cpu0<=spriteram0[cpu_addr[11:2]];sprite_cpu1<=spriteram1[cpu_addr[11:2]];
        sprite_cpu2<=spriteram2[cpu_addr[11:2]];sprite_cpu3<=spriteram3[cpu_addr[11:2]];
        sprite_cpu_select<=cpu_addr[1:0];
        sprite_render0<=spriteram0[{sprite_desc_index,3'd0}];
        sprite_render1<=spriteram1[{sprite_desc_index,3'd0}];
        sprite_render2<=spriteram2[{sprite_desc_index,3'd0}];
        sprite_render3<=spriteram3[{sprite_desc_index,3'd0}];
        text_cpu_code<=text_code[cpu_addr[9:0]];text_cpu_attr<=text_attr[cpu_addr[9:0]];
        text_cpu_select<=cpu_addr[10];
        text_render_code<=text_code[text_tile_index];text_render_attr<=text_attr[text_tile_index];
        palette_render_lo<=palette_lo[color_index];palette_render_hi<=palette_hi[color_index];
        palette_lo_read <= palette_lo[cpu_addr[7:0]];
        palette_hi_read <= palette_hi[cpu_addr[7:0]];
        scroll_read <= scrollram[cpu_addr[4:0]];
        debug_data <= workram[hs_access && pause ? hs_addr : debug_addr];
        video_region_q<=video_region;sprite_video_select<=video_addr[1:0];text_video_select<=video_addr[10];
        sv0<=sprite_video0[video_addr[11:2]];sv1<=sprite_video1[video_addr[11:2]];
        sv2<=sprite_video2[video_addr[11:2]];sv3<=sprite_video3[video_addr[11:2]];
        tvc<=text_video_code[video_addr[9:0]];tva<=text_video_attr[video_addr[9:0]];
        pvl<=palette_video_lo[video_addr[7:0]];pvh<=palette_video_hi[video_addr[7:0]];
        scroll_video<=scrollram[video_addr[4:0]];
        if (hs_access && hs_we && pause && !reset) workram[hs_addr] <= hs_data;
        else if (write_once) begin
            if (cpu_addr >= 16'he000 && cpu_addr <= 16'hefff) workram[cpu_addr[11:0]] <= cpu_dout;
            if (cpu_addr >= 16'hf000) begin
                case(cpu_addr[1:0])
                    2'd0: begin spriteram0[cpu_addr[11:2]]<=cpu_dout; sprite_video0[cpu_addr[11:2]]<=cpu_dout; end
                    2'd1: begin spriteram1[cpu_addr[11:2]]<=cpu_dout; sprite_video1[cpu_addr[11:2]]<=cpu_dout; end
                    2'd2: begin spriteram2[cpu_addr[11:2]]<=cpu_dout; sprite_video2[cpu_addr[11:2]]<=cpu_dout; end
                    default: begin spriteram3[cpu_addr[11:2]]<=cpu_dout; sprite_video3[cpu_addr[11:2]]<=cpu_dout; end
                endcase
            end
            if (cpu_addr >= 16'hd800 && cpu_addr <= 16'hdfff) begin
                if(cpu_addr[10]) begin text_attr[cpu_addr[9:0]]<=cpu_dout;text_video_attr[cpu_addr[9:0]]<=cpu_dout;end
                else begin text_code[cpu_addr[9:0]]<=cpu_dout;text_video_code[cpu_addr[9:0]]<=cpu_dout;end
            end
            if (cpu_addr >= 16'hd000 && cpu_addr <= 16'hd0ff) begin palette_lo[cpu_addr[7:0]] <= cpu_dout;palette_video_lo[cpu_addr[7:0]]<=cpu_dout;end
            if (cpu_addr >= 16'hd200 && cpu_addr <= 16'hd2ff) begin palette_hi[cpu_addr[7:0]] <= cpu_dout;palette_video_hi[cpu_addr[7:0]]<=cpu_dout;end
            if (cpu_addr >= 16'hd400 && cpu_addr <= 16'hd41f) scrollram[cpu_addr[4:0]] <= cpu_dout;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            irq_pending <= 1'b0;
            irq_vector <= 8'hcf;
            hardware_control <= 8'h00;
            sprite_bank <= 8'h00;
            write_seen <= 1'b0;
            response_ready <= 1'b0;
            response_data <= 8'hff;
            trace_write <= 1'b0;
            trace_addr <= 16'h0000;
            trace_data <= 8'h00;
        end else begin
            if (!cpu_iorq_n && !cpu_m1_n && cpu_cen && !pause) irq_pending <= 1'b0;
            if (scanline_tick && (scanline == 8'd0 || scanline == 8'd240)) begin
                irq_pending <= 1'b1;
                irq_vector <= scanline == 8'd0 ? 8'hcf : 8'hd7;
            end
            if (!rom_read) response_ready <= 1'b0;
            else if (rom_valid) begin
                response_ready <= 1'b1;
                response_data <= rom_data;
            end
            if (!memory_write) write_seen <= 1'b0;
            else if (write_once) write_seen <= 1'b1;
            trace_write <= write_once;
            if (write_once) begin
                trace_addr <= cpu_addr;
                trace_data <= cpu_dout;
                if (cpu_addr == 16'hc804) hardware_control <= cpu_dout;
                if (cpu_addr == 16'hc805) sprite_bank <= cpu_dout;
            end
        end
    end

    always @* begin
        cpu_din = 8'hff;
        if (!cpu_iorq_n && !cpu_m1_n) cpu_din = irq_vector;
        else if (rom_read) cpu_din = response_data;
        else if (memory_read) begin
            case (cpu_addr)
                16'hc801: cpu_din = p1;
                16'hc802: cpu_din = p2;
                16'hc803: cpu_din = starts;
                16'hc806: cpu_din = dip1;
                16'hc807: cpu_din = dip2;
                16'hc808: cpu_din = unknown_inputs;
                16'hd681: cpu_din = {7'b0,sound_semaphore};
                default: begin
                    if (cpu_addr >= 16'hd000 && cpu_addr <= 16'hd0ff) cpu_din = palette_lo_read;
                    else if (cpu_addr >= 16'hd200 && cpu_addr <= 16'hd2ff) cpu_din = palette_hi_read;
                    else if (cpu_addr >= 16'hd400 && cpu_addr <= 16'hd41f) cpu_din = scroll_read;
                    else if (cpu_addr >= 16'hd600 && cpu_addr <= 16'hd67f) cpu_din = sound_host_din;
                    else if (cpu_addr >= 16'hd800 && cpu_addr <= 16'hdfff) cpu_din = text_read;
                    else if (cpu_addr >= 16'he000 && cpu_addr <= 16'hefff) cpu_din = work_read;
                    else if (cpu_addr >= 16'hf000) cpu_din = sprite_read;
                end
            endcase
        end
    end
endmodule
