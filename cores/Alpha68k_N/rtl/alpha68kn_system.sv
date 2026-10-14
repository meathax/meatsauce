// Shared real CPU/strip/palette/SDRAM integration. Framework PLL/HPS are external.
module alpha68kn_system (
    input wire clk,cold_reset,reset,downloading,load_wr,
    input wire [24:0] load_addr,
    input wire [15:0] load_data,controls,
    input wire [7:0] dips,
    input wire [1:0] coins_n,
    input wire pause_game,rotate180,hs_access,hs_write,
    input wire [23:0] hs_addr,
    input wire [7:0] hs_data_in,
    output wire [7:0] hs_data_out,
    output wire paused,
    output wire [7:0] profile,dac,
    output wire load_wait,load_busy,initialized,
    output wire raw_ce,raw_hblank,raw_vblank,raw_hs,raw_vs,
    output wire [8:0] raw_x,raw_y,
    output wire video_ce,
    output wire [23:0] video_rgb,
    output wire [7:0] video_x,
    output wire [8:0] video_y,
    output wire video_hblank,video_vblank,video_hs,video_vs,
    output wire sound_io_wr,
    output wire [7:0] sound_io_addr,sound_io_data,
    output wire sound_io_rd,sound_dac_wr,
    output wire [7:0] sound_io_read_addr,sound_io_read_data,
    output wire signed [15:0] audio_sample,
    output wire audio_sample_ce,
    output wire [31:0] audio_clipped_samples,ym_writes,ay1_writes,ay2_writes,
    output wire [23:0] debug_main_addr,
    output wire [15:0] debug_sound_addr,
    output wire [4:0] debug_sound_attrs,
    output wire [7:0] debug_sound_din,debug_sound_dout,
    output wire debug_main_as_n,
    output wire [3:0] debug_main_attrs,
    output wire [15:0] debug_main_din,debug_main_dout,
    output wire [31:0] main_transactions,sound_transactions,work_writes,strip_writes,mcu_transactions,
    output wire [31:0] irq1_acks,irq2_acks,unmapped_accesses,
    input wire [11:0] debug_word_addr,
    output wire [15:0] debug_work_data,debug_strip_data,
    input wire [3:0] debug_rom_kind,
    input wire [15:0] debug_rom_addr,
    output wire [15:0] debug_rom_data,
    output wire [11:0] worst_line_cycles,
    output wire [31:0] completed_lines,deadline_misses,row_overflows,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    wire held_reset=reset || downloading;
    wire [15:0] background;
    wire flip,gfx_wr,gfx_req,gfx_ack,gfx_ready;
    wire [18:0] gfx_load_addr,gfx_addr;
    wire [15:0] gfx_load_data,gfx_data;
    wire [11:0] strip_addr;
    wire [12:0] color_addr;
    wire [7:0] color_data;
    wire [8:0] pen;
    // During reset the diagnostic port can walk RAM; live operation uses the
    // same synchronous strip-RAM port for the actual scanline renderer.
    alpha68kn_board board (
        .clk(clk),.reset(reset),.downloading(downloading),.load_wr(load_wr),
        .load_addr(load_addr),.load_data(load_data),.controls(controls),.dips(dips),.coins_n(coins_n),
        .pause_game(pause_game),.paused(paused),.hs_access(hs_access),.hs_addr(hs_addr),
        .hs_write(hs_write),.hs_data_in(hs_data_in),.hs_data_out(hs_data_out),
        .profile(profile),.ce_pix(raw_ce),.x(raw_x),.y(raw_y),.hblank(raw_hblank),.vblank(raw_vblank),
        .hs(raw_hs),.vs(raw_vs),.gfx_load_wr(gfx_wr),.gfx_load_addr(gfx_load_addr),.gfx_load_data(gfx_load_data),
        .background(background),.background_rgb(),.flip(flip),.dac(dac),
        .sound_io_wr(sound_io_wr),.sound_io_addr(sound_io_addr),.sound_io_data(sound_io_data),
        .sound_io_rd(sound_io_rd),.sound_io_read_addr(sound_io_read_addr),
        .sound_io_read_data(sound_io_read_data),.sound_dac_wr(sound_dac_wr),
        .debug_main_addr(debug_main_addr),.debug_sound_addr(debug_sound_addr),.debug_main_as_n(debug_main_as_n),
        .debug_sound_attrs(debug_sound_attrs),.debug_sound_din(debug_sound_din),.debug_sound_dout(debug_sound_dout),
        .debug_main_attrs(debug_main_attrs),.debug_main_din(debug_main_din),.debug_main_dout(debug_main_dout),
        .main_transactions(main_transactions),.sound_transactions(sound_transactions),
        .work_writes(work_writes),.strip_writes(strip_writes),.mcu_transactions(mcu_transactions),
        .irq1_acks(irq1_acks),.irq2_acks(irq2_acks),.unmapped_accesses(unmapped_accesses),
        .debug_word_addr(held_reset ? debug_word_addr : strip_addr),
        .debug_work_data(debug_work_data),.debug_strip_data(debug_strip_data),
        .debug_rom_kind(debug_rom_kind),.debug_rom_addr(debug_rom_addr),.debug_rom_data(debug_rom_data)
    );
    alpha68kn_audio audio (
        .clk(clk),.reset(held_reset),.io_wr(sound_io_wr),.io_rd(sound_io_rd),
        .io_addr(sound_io_addr),.io_data(sound_io_data),.read_addr(sound_io_read_addr),
        .read_data(sound_io_read_data),.profile(profile),.dac(dac),
        .sample(audio_sample),.sample_ce(audio_sample_ce),.clipped_samples(audio_clipped_samples),
        .debug_fm(),.debug_ym_psg(),.debug_ay1_psg(),.debug_ay2_psg(),
        .ym_writes(ym_writes),.ay1_writes(ay1_writes),.ay2_writes(ay2_writes)
    );
    alpha68kn_renderer renderer (
        .clk(clk),.reset(held_reset),.line_start(raw_ce && raw_x==0),.line_y(raw_y),
        .video_y(raw_y),.video_x(raw_x[7:0]),.video_pen(pen),.flip(flip),.stingray(profile==2),.rotate180(rotate180),
        .strip_addr(strip_addr),.strip_data(debug_strip_data),.color_addr(color_addr),.color_data(color_data),
        .gfx_req(gfx_req),.gfx_addr(gfx_addr),.gfx_ack(gfx_ack),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .worst_line_cycles(worst_line_cycles),.completed_lines(completed_lines),
        .deadline_misses(deadline_misses),.row_overflows(row_overflows)
    );
    alpha68kn_video_rom video_rom (
        .clk(clk),.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),
        .color_addr(color_addr),.color_data(color_data),.pen(pen),.background(background[7:0]),
        .rgb(video_rgb),.debug_kind(4'd0),.debug_addr(13'd0),.debug_data()
    );
    reg [11:0] refresh_count=0;
    always @(posedge clk) begin
        if(cold_reset || refresh_count==3071) refresh_count<=0;
        else refresh_count<=refresh_count+1'b1;
    end
    alpha68kn_gfxmem gfxmem (
        .clk(clk),.reset(cold_reset),.load_wr(gfx_wr),.load_addr(gfx_load_addr),.load_data(gfx_load_data),
        .load_wait(load_wait),.load_busy(load_busy),.initialized(initialized),.loaded_words(),
        .refresh(refresh_count==3071),.read_req(gfx_req),.read_addr(gfx_addr),
        .read_ack(gfx_ack),.read_ready(gfx_ready),.read_data(gfx_data),.sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
    // Line-buffer read, CLUT and RGB PROM stages consume three master edges.
    reg [2:0] ce_pipe,hb_pipe,vb_pipe,hs_pipe,vs_pipe;
    reg [7:0] xp0,xp1,xp2;
    reg [8:0] yp0,yp1,yp2;
    always @(posedge clk) begin
        if(held_reset) begin
            ce_pipe<=0;hb_pipe<=7;vb_pipe<=7;hs_pipe<=7;vs_pipe<=7;
            xp0<=0;xp1<=0;xp2<=0;yp0<=0;yp1<=0;yp2<=0;
        end else begin
            ce_pipe<={ce_pipe[1:0],raw_ce};hb_pipe<={hb_pipe[1:0],raw_hblank};
            vb_pipe<={vb_pipe[1:0],raw_vblank};hs_pipe<={hs_pipe[1:0],raw_hs};
            vs_pipe<={vs_pipe[1:0],raw_vs};
            xp0<=raw_x[7:0];xp1<=xp0;xp2<=xp1;
            yp0<=raw_y;yp1<=yp0;yp2<=yp1;
        end
    end
    assign video_ce=ce_pipe[2];
    assign video_hblank=hb_pipe[2];assign video_vblank=vb_pipe[2];
    assign video_hs=hs_pipe[2];assign video_vs=vs_pipe[2];
    assign video_x=xp2;assign video_y=yp2;
endmodule
