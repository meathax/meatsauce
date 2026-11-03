// SPDX-License-Identifier: GPL-3.0-or-later
// Spinal Breakers 68000 map. Registered reads and one side effect per DS assertion.
module spinal_main_bus #(parameter bit FRAME_SCROLL=0)(
    input logic clk, reset,
    input logic video_snapshot_hold,
    input logic [23:0] address,
    input logic as_n, uds_n, lds_n, read_not_write,
    input logic [2:0] fc,
    input logic [15:0] cpu_data_out,
    // Byte-wide high-score access to work RAM, only after pause acknowledgement.
    input logic score_request,score_paused,score_write,
    input logic [13:0] score_address,input logic [7:0] score_data_in,
    output wire score_ready,output wire [7:0] score_data_out,
    output logic [15:0] cpu_data_in,
    output logic dtack_n, vpa_n,
    output logic rom_req,
    output logic [17:1] rom_address,
    input logic rom_ok,
    input logic [15:0] rom_data,
    input logic [15:0] in0, in1, dips,
    output logic [7:0] sound_command,
    output logic sound_write,
    output logic flip_screen,
    output logic [7:0] gfxbank,
    output logic [15:0] scrollx1,
    output logic [3:0] gga_index,
    output logic [7:0] gga_data,
    output logic gga_write,
    input logic [10:0] video_vram_address,
    input logic [9:0] video_sprite_address, video_palette_address,
    input logic [7:0] video_row_address,
    output logic [15:0] video_vram0, video_vram1,
    output logic [15:0] video_sprite, video_palette, video_row,
    output logic [63:0] video_sprite_block,
    output wire video_write_commit
);
    logic issued, response, discard_rom, armed;
    logic [1:0] sprite_read_lane;
    wire strobe = !as_n && !(uds_n && lds_n);
    wire iack = !as_n && fc == 3'b111;
    assign dtack_n = !response || !strobe || iack;
    assign vpa_n = !iack;
    assign video_write_commit = cpu_accept && !read_not_write;
    assign video_sprite=video_sprite_block[sprite_read_lane*16+:16];

    // Dedicated unreset RAM read registers permit native block-memory inference.
    // The selected reply and each read register hold until the next admission,
    // preserving the original one-edge CPU reply and idle data-bus retention.
    logic [15:0] cpu_fixed_data;
    logic [3:0] cpu_ram_source;
    // Keep the table stable during the short frame copy. Stall only writes to
    // the snapshotted state; reads and unrelated CPU traffic remain eligible.
    wire snapshot_write_block=FRAME_SCROLL && video_snapshot_hold && !read_not_write &&
        ((address>=24'hffd000 && address<24'hffd200) ||
         (address>=24'hfff000 && address<24'hfff004));
    wire cpu_accept = !reset && strobe && !iack && !issued && !rom_req && armed && !snapshot_write_block;
    logic [15:0] cpu_workram_q;
    logic [15:0] cpu_vram0_q;
    logic [15:0] cpu_vram1_q;
    logic [15:0] cpu_sprites0_q;
    logic [15:0] cpu_sprites1_q;
    logic [15:0] cpu_sprites2_q;
    logic [15:0] cpu_sprites3_q;
    logic [15:0] cpu_rowscroll_q;
    logic [15:0] cpu_palette_q;
    always_comb begin
        case(cpu_ram_source)
        4'd1: cpu_data_in=cpu_workram_q;
        4'd2: cpu_data_in=cpu_vram0_q;
        4'd3: cpu_data_in=cpu_vram1_q;
        4'd4: cpu_data_in=cpu_sprites0_q;
        4'd5: cpu_data_in=cpu_sprites1_q;
        4'd6: cpu_data_in=cpu_sprites2_q;
        4'd7: cpu_data_in=cpu_sprites3_q;
        4'd8: cpu_data_in=cpu_rowscroll_q;
        4'd9: cpu_data_in=cpu_palette_q;
        default: cpu_data_in=cpu_fixed_data;
        endcase
    end

    wire [15:0] video_sprites0,video_sprites1,video_sprites2,video_sprites3;
    assign video_sprite_block={video_sprites3,video_sprites2,video_sprites1,video_sprites0};
    logic score_busy,score_lane;
    wire score_accept=!reset && score_request && score_paused && as_n && !score_busy;
    assign score_ready=score_busy && score_request && score_paused && !reset;
    assign score_data_out=score_lane ? cpu_workram_q[7:0] : cpu_workram_q[15:8];
    always_ff @(posedge clk) begin
        if(reset || !score_request || !score_paused) score_busy<=0;
        else if(score_accept) begin score_busy<=1;score_lane<=score_address[0];end
    end
    spinal_bus_ram #(.AW(13)) workram_ram(
        .clk(clk),.cpu_enable(score_accept || (cpu_accept && (address>=24'hff8000 && address<24'hffc000))),
        .cpu_address(score_accept ? score_address[13:1] : address[13:1]),
        .cpu_write(score_accept ? score_write : !read_not_write),
        .cpu_byte_enable(score_accept ? (score_address[0] ? 2'b01 : 2'b10) : {!uds_n,!lds_n}),
        .cpu_data(score_accept ? {score_data_in,score_data_in} : cpu_data_out),
        .cpu_q(cpu_workram_q),.video_address(13'd0),.video_q());
    spinal_bus_ram #(.AW(11)) vram0_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'h080000 && address<24'h081000)),.cpu_address(address[11:1]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_vram0_q),.video_address(video_vram_address),.video_q(video_vram0));
    spinal_bus_ram #(.AW(11)) vram1_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'h082000 && address<24'h083000)),.cpu_address(address[11:1]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_vram1_q),.video_address(video_vram_address),.video_q(video_vram1));
    spinal_bus_ram #(.AW(8)) sprites0_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffc000 && address<24'hffc800 && address[2:1]==2'd0)),.cpu_address(address[10:3]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_sprites0_q),.video_address(video_sprite_address[9:2]),.video_q(video_sprites0));
    spinal_bus_ram #(.AW(8)) sprites1_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffc000 && address<24'hffc800 && address[2:1]==2'd1)),.cpu_address(address[10:3]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_sprites1_q),.video_address(video_sprite_address[9:2]),.video_q(video_sprites1));
    spinal_bus_ram #(.AW(8)) sprites2_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffc000 && address<24'hffc800 && address[2:1]==2'd2)),.cpu_address(address[10:3]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_sprites2_q),.video_address(video_sprite_address[9:2]),.video_q(video_sprites2));
    spinal_bus_ram #(.AW(8)) sprites3_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffc000 && address<24'hffc800 && address[2:1]==2'd3)),.cpu_address(address[10:3]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_sprites3_q),.video_address(video_sprite_address[9:2]),.video_q(video_sprites3));
    spinal_bus_ram #(.AW(8)) rowscroll_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffd000 && address<24'hffd200)),.cpu_address(address[8:1]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_rowscroll_q),.video_address(video_row_address),.video_q(video_row));
    spinal_bus_ram #(.AW(10)) palette_ram(
        .clk(clk),.cpu_enable(cpu_accept && (address>=24'hffe000 && address<24'hffe800)),.cpu_address(address[10:1]),
        .cpu_write(!read_not_write),.cpu_byte_enable({!uds_n,!lds_n}),.cpu_data(cpu_data_out),
        .cpu_q(cpu_palette_q),.video_address(video_palette_address),.video_q(video_palette));

    always_ff @(posedge clk) begin
        sprite_read_lane <= video_sprite_address[1:0];
        sound_write <= 1'b0;
        gga_write <= 1'b0;

        if(reset) begin
            issued<=1'b0; response<=1'b0; armed<=1'b0; cpu_fixed_data<=16'hffff; cpu_ram_source<=4'd0;
            flip_screen<=1'b0; gfxbank<='0; scrollx1<='0;
            gga_index<='0; gga_data<='0; sound_command<='0;
            // Keep any accepted ROM tuple alive through reset and drain its reply.
            if(rom_req) begin
                if(rom_ok) begin rom_req<=1'b0; discard_rom<=1'b0; end
                else discard_rom<=1'b1;
            end else begin rom_req<=1'b0; discard_rom<=1'b0; end
        end else begin
            if(as_n) armed<=1'b1;
            if(!strobe) begin
                issued<=1'b0; response<=1'b0;
                if(rom_req) discard_rom<=1'b1;
            end
            if(rom_req && rom_ok) begin
                rom_req<=1'b0;
                if(!discard_rom && strobe) begin cpu_fixed_data<=rom_data; response<=1'b1; end
                discard_rom<=1'b0;
            end
            if(strobe && !iack && !issued && !rom_req && armed && !snapshot_write_block) begin
                issued<=1'b1;
                response<=1'b1;
                cpu_fixed_data<=16'hffff; cpu_ram_source<=4'd0;
                if(address < 24'h040000) begin
                    if(read_not_write) begin
                        rom_address<=address[17:1];rom_req<=1'b1;discard_rom<=1'b0;response<=1'b0;
                    end
                end else if(address>=24'hff8000 && address<24'hffc000) begin
                    cpu_ram_source<=4'd1;
                end else if(address>=24'h080000 && address<24'h081000) begin
                    cpu_ram_source<=4'd2;
                end else if(address>=24'h082000 && address<24'h083000) begin
                    cpu_ram_source<=4'd3;
                end else if(address>=24'hffc000 && address<24'hffc800) begin
                    case(address[2:1])
                        0: cpu_ram_source<=4'd4;
                        1: cpu_ram_source<=4'd5;
                        2: cpu_ram_source<=4'd6;
                        3: cpu_ram_source<=4'd7;
                    endcase
                end else if(address>=24'hffd000 && address<24'hffd200) begin
                    cpu_ram_source<=4'd8;
                end else if(address>=24'hffe000 && address<24'hffe800) begin
                    cpu_ram_source<=4'd9;
                end else case(address)
                    24'hfff000: begin
                        cpu_fixed_data<=in0;
                        if(!read_not_write) begin
                            if(!uds_n) flip_screen<=cpu_data_out[15];
                            if(!lds_n) gfxbank<=cpu_data_out[7:0];
                        end
                    end
                    24'hfff002: begin
                        cpu_fixed_data<=in1;
                        if(!read_not_write) begin
                            if(!uds_n) scrollx1[15:8]<=cpu_data_out[15:8];
                            if(!lds_n) scrollx1[7:0]<=cpu_data_out[7:0];
                        end
                    end
                    24'hfff004: cpu_fixed_data<=dips;
                    24'hfff006: if(!read_not_write && !lds_n) begin sound_command<=cpu_data_out[7:0];sound_write<=1'b1; end
                    24'hfff400: if(!read_not_write && !lds_n) begin gga_data<=cpu_data_out[7:0];gga_write<=1'b1; end
                    24'hfff402: if(!read_not_write && !lds_n) gga_index<=cpu_data_out[3:0];
                    default: ;
                endcase
            end
        end
    end
endmodule

// Registered two-port board RAM, with byte lanes represented explicitly.
// CPU read/write shares one address; video observes an independent synchronous
// read. Consumers defer colliding CPU/video accesses in the memory adapter.
module spinal_bus_ram #(parameter integer AW=8)(
 input wire clk,cpu_enable,cpu_write,
 input wire [AW-1:0] cpu_address,video_address,
 input wire [1:0] cpu_byte_enable,
 input wire [15:0] cpu_data,
 output wire [15:0] cpu_q,video_q
);
`ifndef VERILATOR
 // Independent simple-dual-port byte copies retain OLD_DATA and CPU hold.
 genvar lane;
 generate for(lane=0;lane<2;lane=lane+1) begin:bytes
  altsyncram #(
   .intended_device_family("Cyclone V"),.operation_mode("DUAL_PORT"),
   .ram_block_type("M10K"),.width_a(8),.width_b(8),
   .widthad_a(AW),.widthad_b(AW),.numwords_a(1<<AW),.numwords_b(1<<AW),
   .width_byteena_a(1),.width_byteena_b(1),.address_reg_b("CLOCK0"),
   .outdata_reg_b("UNREGISTERED"),.clock_enable_input_a("NORMAL"),
   .clock_enable_input_b("NORMAL"),.clock_enable_output_b("BYPASS"),
   .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("FALSE")
  ) cpu_copy(
   .clock0(clk),.clocken0(cpu_enable),
   .clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),
   .address_a(cpu_address),.address_b(cpu_address),
   .data_a(cpu_data[lane*8+:8]),.data_b(8'd0),
   .wren_a(cpu_write && cpu_byte_enable[lane]),.wren_b(1'b0),
   .rden_a(1'b1),.rden_b(1'b1),.byteena_a(1'b1),.byteena_b(1'b1),
   .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
   .q_a(),.q_b(cpu_q[lane*8+:8]),.eccstatus());
  altsyncram #(
   .intended_device_family("Cyclone V"),.operation_mode("DUAL_PORT"),
   .ram_block_type("M10K"),.width_a(8),.width_b(8),
   .widthad_a(AW),.widthad_b(AW),.numwords_a(1<<AW),.numwords_b(1<<AW),
   .width_byteena_a(1),.width_byteena_b(1),.address_reg_b("CLOCK0"),
   .outdata_reg_b("UNREGISTERED"),.clock_enable_input_a("NORMAL"),
   .clock_enable_input_b("NORMAL"),.clock_enable_output_b("BYPASS"),
   .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("FALSE")
  ) video_copy(
   .clock0(clk),.clocken0(1'b1),
   .clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),
   .address_a(cpu_address),.address_b(video_address),
   .data_a(cpu_data[lane*8+:8]),.data_b(8'd0),
   .wren_a(cpu_enable && cpu_write && cpu_byte_enable[lane]),.wren_b(1'b0),
   .rden_a(1'b1),.rden_b(1'b1),.byteena_a(1'b1),.byteena_b(1'b1),
   .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
   .q_a(),.q_b(video_q[lane*8+:8]),.eccstatus());
 end endgenerate
`else
 // The portable branch is checked against Intel's native model separately.
 reg [1:0][7:0] mem[0:(1<<AW)-1] /* verilator public_flat_rd */;
 reg [15:0] cpu_q_reg,video_q_reg;
 assign cpu_q=cpu_q_reg;assign video_q=video_q_reg;
 integer lane;
 always @(posedge clk) begin
  if(cpu_enable) begin
   cpu_q_reg <= mem[cpu_address];
   if(cpu_write) for(lane=0;lane<2;lane=lane+1)
    if(cpu_byte_enable[lane]) mem[cpu_address][lane] <= cpu_data[lane*8+:8];
  end
  video_q_reg <= mem[video_address];
 end
`endif
endmodule
