// Shared production board: real chips, on-chip RAM, external ROM clients.
// Raster renderer, SDRAM arbitration and MiSTer wrapper attach to these interfaces.
module steel_board #(parameter HISCORE_PORT=0)(
    input wire clk, reset, pause_cpu, mortalr, cpu_turbo,
    // Sprite buffer swaps are applied at this once-per-frame display latch while the renderer is idle.
    input wire sprite_latch, render_busy,
    input wire [15:0] input_word, system_word,
    output wire rom_req,
    output wire [18:0] rom_word_addr,
    input wire rom_ready,
    input wire [15:0] rom_rdata,
    input wire video_en,
    input wire [16:0] video_word_addr,
    output wire [15:0] video_rdata,
    input wire [5:0] nv_addr,
    input wire nv_we,
    input wire [15:0] nv_din,
    output wire [15:0] nv_dout,
    output wire [17:0] oki_addr,
    input wire [7:0] oki_data,
    input wire oki_ok,
    output wire signed [13:0] audio,
    output wire audio_sample,
    output wire debug_io_accept,
    output wire [15:0] debug_io_rdata,
    output wire video_command_valid,
    output wire [15:0] video_command,
    input wire sprite_en,
    input wire [7:0] sprite_index,
    output wire [63:0] sprite_data,
    output wire sprite_busy,sprite_which,sprite_active_bank,
    output wire [31:0] frame_number,
    output wire frame_tick, vblank,
    output wire [23:0] debug_cpu_addr,
    output wire [15:0] debug_cpu_wdata,
    output wire [2:0] debug_fc,
    output wire debug_asn, debug_rwn, debug_haltedn, irq_pending, irq_ack,
    output wire mem_valid, mem_write, mem_ready,
    output wire [23:0] mem_addr,
    output wire [15:0] mem_wdata, debug_mem_rdata,
    output wire [1:0] mem_lanes,
    input wire hs_en, hs_write,
    input wire [23:0] hs_addr,
    input wire [7:0] hs_din,
    output wire [7:0] hs_dout
);
    wire command_done,dma_en;
    wire [16:0] dma_word_addr;
    wire [15:0] dma_rdata;
    steel_sprite_buffer sprite_buffer(
        .clk(clk),.reset(reset),.command_valid(video_command_valid),.command(video_command),
        .command_done(command_done),.busy(sprite_busy),.dma_en(dma_en),.dma_word_addr(dma_word_addr),.dma_rdata(dma_rdata),
        .sprite_en(sprite_en),.sprite_index(sprite_index),.sprite_data(sprite_data),
        .which(sprite_which),.active_bank(sprite_active_bank),
        .display_latch(sprite_latch),.render_busy(render_busy));
    wire mem_write_grant;
    steel_cpu_board chips(
        .clk(clk),.reset(reset),.pause_cpu(pause_cpu),.mortalr(mortalr),.cpu_turbo(cpu_turbo),
        .input_word(input_word),.system_word(system_word),
        .mem_valid(mem_valid),.mem_write(mem_write),.mem_addr(mem_addr),
        .mem_wdata(mem_wdata),.mem_lanes(mem_lanes),
        .mem_ready(mem_ready),.mem_write_grant(mem_write_grant),.mem_rdata(debug_mem_rdata),
        .nv_addr(nv_addr),.nv_we(nv_we),.nv_din(nv_din),.nv_dout(nv_dout),
        .oki_addr(oki_addr),.oki_data(oki_data),.oki_ok(oki_ok),.audio(audio),.audio_sample(audio_sample),
        .debug_io_accept(debug_io_accept),.debug_io_rdata(debug_io_rdata),
        .video_command_valid(video_command_valid),.video_command(video_command),.video_command_done(command_done),
        .frame_number(frame_number),.frame_tick(frame_tick),.vblank(vblank),
        .debug_cpu_addr(debug_cpu_addr),.debug_cpu_wdata(debug_cpu_wdata),.debug_fc(debug_fc),
        .debug_asn(debug_asn),.debug_rwn(debug_rwn),.debug_haltedn(debug_haltedn),
        .irq_pending(irq_pending),.irq_ack(irq_ack));
    steel_memory #(.HISCORE_PORT(HISCORE_PORT)) memory(
        .clk(clk),.reset(reset),.mortalr(mortalr),
        .cpu_valid(mem_valid),.cpu_write(mem_write),.cpu_addr(mem_addr),
        .cpu_wdata(mem_wdata),.cpu_lanes(mem_lanes),.cpu_ready(mem_ready),.cpu_write_grant(mem_write_grant),.cpu_rdata(debug_mem_rdata),
        .rom_req(rom_req),.rom_word_addr(rom_word_addr),.rom_ready(rom_ready),.rom_rdata(rom_rdata),
        .dma_en(dma_en),.dma_word_addr(dma_word_addr),.dma_rdata(dma_rdata),
        .video_en(video_en),.video_word_addr(video_word_addr),.video_rdata(video_rdata),
        .hs_en(hs_en && pause_cpu),.hs_write(hs_write),.hs_addr(hs_addr),.hs_din(hs_din),.hs_dout(hs_dout));
endmodule
