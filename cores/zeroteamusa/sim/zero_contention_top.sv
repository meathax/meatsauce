// Graphics deadline bench: the real video engines, ROM bridge and SDRAM
// controller against a pin-level SDRAM model and a worst-case CPU load.
// Scene memories come from MAME captures (see scripts/run_contention.py).
// ideal=1 bypasses bridge+SDRAM with a fixed 3-clock graphics response
// (the old isolated fixture contract) to produce the same-scene reference.
module zero_contention_top (
    input wire clk, reset, ideal, flip, no_reserve,
    input wire [4:0] layer_enable,
    input wire [15:0] bg_x,bg_y,mg_x,mg_y,fg_x,fg_y,
    // ideal-mode graphics response (driven by C++)
    input wire [31:0] ideal_data,
    input wire ideal_valid,
    input wire [31:0] ideal_spr_data,
    input wire ideal_spr_valid, ideal_spr_half,
    output wire sprite_request,
    output wire [23:0] sprite_address,
    // CPU stress (driven by C++)
    input wire main_req, cop_req,
    input wire [23:0] main_address, cop_address,
    input wire [17:0] oki_address,
    output wire main_valid, cop_valid,
    output wire oki_valid_o,
    // SDRAM pins
    input wire [15:0] model_dq,
    output wire [15:0] pin_write_data,
    output wire pin_dq_oe,
    output wire [2:0] command,
    output wire [12:0] pin_address,
    output wire [1:0] bank, dqm,
    output wire sdram_ready,
    // video
    output wire rom_request,
    output wire [23:0] rom_address,
    output wire [2:0] rom_kind,
    output wire ce_pixel,
    output wire [7:0] r,g,b,
    output wire pixel_strobe,pixel_display,
    output wire [9:0] pixel_x,
    output wire [8:0] pixel_y,
    // deadline instrumentation
    output reg  [31:0] spr_overruns, tile_overruns,
    output reg  [15:0] spr_max_cycles,
    output reg         line_event,
    output reg  [15:0] line_cycles,
    output reg  [8:0]  line_y,
    output reg         line_overrun,
    output wire        video_urgent_o
);
    assign video_urgent_o = video_urgent;
    wire [10:0] bg_a,mg_a,fg_a,tx_a,spr_a,pal_a;
    reg [15:0] bgm[0:2047],mgm[0:2047],fgm[0:2047],txm[0:2047],sprm[0:2047],palm[0:2047];
    initial begin
        $readmemh("build/contention/scene/bg.mem",bgm);
        $readmemh("build/contention/scene/mg.mem",mgm);
        $readmemh("build/contention/scene/fg.mem",fgm);
        $readmemh("build/contention/scene/text.mem",txm);
        $readmemh("build/contention/scene/sprite.mem",sprm);
        $readmemh("build/contention/scene/palette.mem",palm);
    end
    reg [15:0] bg_q,mg_q,fg_q,tx_q,spr_q,pal_q;
    always @(posedge clk) begin
        bg_q<=bgm[bg_a]; mg_q<=mgm[mg_a]; fg_q<=fgm[fg_a]; tx_q<=txm[tx_a]; spr_q<=sprm[spr_a]; pal_q<=palm[pal_a];
    end

    wire [31:0] gfx_data;
    wire gfx_valid;
    wire spr_req, spr_valid, spr_half;
    wire [23:0] spr_address;
    wire [31:0] spr_data;
    wire [1:0] sd_len0;
    wire sd_beat0;
    wire video_urgent = 1'b0;   // no deadline reservation in the design
    wire [31:0] video_rom_data = ideal ? ideal_data : gfx_data;
    wire video_rom_valid = ideal ? ideal_valid : gfx_valid;
    wire de,vb,hb,hs,vs;
    wire [9:0] x;
    wire [8:0] y;
    wire video_reset = reset || !sdram_ready;   // platform: reset_cause includes !sdram_ready
    ZeroTeam_video video (
        .clk(clk),.reset(video_reset),.timing_reset(video_reset),.layer_enable(layer_enable),.flip_screen(flip),
        .bg_x(bg_x),.bg_y(bg_y),.mg_x(mg_x),.mg_y(mg_y),.fg_x(fg_x),.fg_y(fg_y),.tx_x(16'd0),.tx_y(16'd0),
        .bg_address(bg_a),.mg_address(mg_a),.fg_address(fg_a),.tx_address(tx_a),.spr_address(spr_a),.pal_address(pal_a),
        .bg_data(bg_q),.mg_data(mg_q),.fg_data(fg_q),.tx_data(tx_q),.spr_data(spr_q),.pal_data(pal_q),
        .rom_request(rom_request),.rom_address(rom_address),.rom_kind(rom_kind),
        .rom_data(video_rom_data),.rom_valid(video_rom_valid),
        .sprite_rom_request(spr_req),.sprite_rom_address(spr_address),
        .sprite_rom_data(ideal ? ideal_spr_data : spr_data),.sprite_rom_valid(ideal ? ideal_spr_valid : spr_valid),
        .sprite_rom_half(ideal ? ideal_spr_half : spr_half),
        .ce_pixel(ce_pixel),.display_enable(de),.hblank(hb),.vblank(vb),.hsync(hs),.vsync(vs),
        .x(x),.y(y),.r(r),.g(g),.b(b),
        .pixel_strobe(pixel_strobe),.pixel_display(pixel_display),.pixel_x(pixel_x),.pixel_y(pixel_y)
    );

    wire [23:0] sd_addr[0:3];
    wire [15:0] sd_data[0:3],sd_write_data;
    wire [3:0] sd_req,sd_ack;
    wire sd_write;
    wire [15:0] dq;
    assign dq = memory.sdram_dq_oe ? 16'bz : model_dq;
    assign pin_write_data = memory.sdram_dq_out;
    assign pin_dq_oe = memory.sdram_dq_oe;
    wire nras,ncas,nwe;
    assign command = {nras,ncas,nwe};
    sdram memory (
        .clk(clk),.init(reset),.prio_mode(2'b01),.ready(sdram_ready),
        .SDRAM_DQ(dq),.SDRAM_A(pin_address),.SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),
        .SDRAM_BA(bank),.SDRAM_nCS(),.SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),
        .SDRAM_CLK(),.SDRAM_CKE(),
        .addr0(sd_addr[0]),.wrl0(sd_write),.wrh0(sd_write),.din0(sd_write_data),
        .dout0(sd_data[0]),.req0(sd_req[0]),.ack0(sd_ack[0]),
        .rd_len0(sd_len0),.beat0(sd_beat0),
        .addr1(sd_addr[1]),.wrl1(1'b0),.wrh1(1'b0),.din1(16'd0),
        .dout1(sd_data[1]),.req1(sd_req[1]),.ack1(sd_ack[1]),
        .addr2(sd_addr[2]),.wrl2(1'b0),.wrh2(1'b0),.din2(16'd0),
        .dout2(sd_data[2]),.req2(sd_req[2]),.ack2(sd_ack[2]),
        .addr3(sd_addr[3]),.wrl3(1'b0),.wrh3(1'b0),.din3(16'd0),
        .dout3(sd_data[3]),.req3(sd_req[3]),.ack3(sd_ack[3])
    );
    wire [15:0] main_data,cop_data;
    wire [7:0] oki_data;
    wire oki_valid;
    assign oki_valid_o = oki_valid;
    ZeroTeam_rom_bridge roms (
        .clk(clk),.reset(reset),.ready(sdram_ready),.download(1'b0),
        .word_wr(1'b0),.word_address(27'd0),.word_data(16'd0),
        .download_wait(),.download_busy(),
        .gfx_req(rom_request && !ideal),.gfx_address(rom_address),
        .gfx_kind(rom_kind),.gfx_data(gfx_data),.gfx_valid(gfx_valid),
        .spr_req(spr_req && !ideal),.spr_address(spr_address),.spr_data(spr_data),
        .spr_valid(spr_valid),.spr_half(spr_half),.len0(sd_len0),.beat0(sd_beat0),
        .main_req(main_req),.main_address(main_address),.main_data(main_data),.main_valid(main_valid),
        .cop_req(cop_req),.cop_address(cop_address),.cop_data(cop_data),.cop_valid(cop_valid),
        .oki_address(oki_address),.oki_data(oki_data),.oki_valid(oki_valid),
        .addr0(sd_addr[0]),.addr1(sd_addr[1]),.addr2(sd_addr[2]),.addr3(sd_addr[3]),
        .din0(sd_write_data),.we0(sd_write),.req0(sd_req[0]),.req1(sd_req[1]),
        .req2(sd_req[2]),.req3(sd_req[3]),.ack0(sd_ack[0]),.ack1(sd_ack[1]),
        .ack2(sd_ack[2]),.ack3(sd_ack[3]),.dout0(sd_data[0]),.dout1(sd_data[1]),
        .dout2(sd_data[2]),.dout3(sd_data[3])
    );

    assign sprite_request = spr_req;
    assign sprite_address = spr_address;

    // ── Deadline instrumentation (observes, never drives, the DUT) ──
    wire spr_start = video.sprite_layer.gated_new_line;
    wire [3:0] spr_state = video.sprite_layer.sc_state;
    wire spr_busy = spr_state != 4'd0 && spr_state != 4'd13;
    wire tile_late = (video.bg_layer.gated_new_line && video.bg_layer.pf_state != 4'd0 && video.bg_layer.pf_state != 4'd8) ||
                     (video.mg_layer.gated_new_line && video.mg_layer.pf_state != 4'd0 && video.mg_layer.pf_state != 4'd8) ||
                     (video.fg_layer.gated_new_line && video.fg_layer.pf_state != 4'd0 && video.fg_layer.pf_state != 4'd8);
    reg [15:0] count;
    reg running, done_seen;
    reg [8:0] cur_y;
    always @(posedge clk) begin
        line_event <= 1'b0;
        if (video_reset) begin
            spr_overruns<=0; tile_overruns<=0; spr_max_cycles<=0; count<=0; running<=0; done_seen<=0;
        end else begin
            if (tile_late) tile_overruns <= tile_overruns + 1;
            if (spr_start) begin
                if (running) begin
                    // previous line still busy: overrun, report its full slot
                    if (spr_busy) spr_overruns <= spr_overruns + 1;
                    line_event <= 1'b1; line_cycles <= count; line_y <= cur_y; line_overrun <= spr_busy;
                end
                running <= 1'b1; count <= 0; cur_y <= video.sprite_layer.target_y;
            end else if (running) begin
                count <= count + 1;
                if (spr_state == 4'd13) begin
                    running <= 1'b0;
                    line_event <= 1'b1; line_cycles <= count; line_y <= cur_y; line_overrun <= 1'b0;
                    if (count > spr_max_cycles) spr_max_cycles <= count;
                end
            end
        end
    end
endmodule
