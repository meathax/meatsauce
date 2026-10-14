// SPDX-License-Identifier: GPL-3.0-or-later
// Integration bench: real GPU (line-burst port) + display scanout + CPU-like peer through the
// real arbiter, memory fabric and SDRAM controller. Used to prove the GPU burst path does not
// starve the display and that the rendered frame equals MAME through the physical memory.
module cs_gpu_fabric #(parameter bit MAME_PALETTE_HACK=1, parameter bit SCAN_BURST=1) (
    input logic clk,reset,
    input logic peer_valid,
    input logic [31:0] peer_address,
    output logic peer_ready,peer_rsp_valid,
    output logic [31:0] peer_rsp_data,
    output logic peer_rsp_error,
    input logic gpu_vblank,
    // CPU/DMA texture writes the bench applies straight to the SDRAM model (snooped like the board's).
    input logic bench_snoop_valid,
    input logic [17:0] bench_snoop_line,
    input logic reg_valid,reg_write,
    input logic [15:0] reg_address,
    input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,
    output logic reg_ready,reg_rsp_valid,reg_rsp_error,
    output logic [31:0] reg_rsp_data,
    output logic gpu_busy,gpu_fault,gpu_flip_sync,gpu_display_bank,
    output logic [10:0] gpu_queue_front,gpu_queue_rear,
    output logic [22:0] gpu_draw_address,gpu_display_address,
    output logic [31:0] gpu_packets,gpu_pixels,gpu_fault_address,
    // Instrumentation (render-cost accounting only).
    output logic [4:0] stat_gpu_state,
    output logic stat_scan_fetching,stat_burst_start,stat_burst_write,stat_burst_region,stat_scan_valid,stat_scan_ready,stat_scan_rsp,stat_fill_b,stat_pipe_fill,stat_be_bursting,stat_be_burst_write,stat_be_burst_frame,stat_be_busy,stat_be_cmd_act,stat_be_cmd_rw,stat_advance,stat_write_stall,
    output logic [17:0] stat_burst_line,
    output logic stat_pf_accept,stat_pf_used,
    output logic memory_initialized,video_tick,video_de,video_armed,video_underrun,video_fault,vblank,
    output logic [11:0] video_x,video_y,
    output logic [7:0] video_r,video_g,video_b,
    input logic [15:0] sdram_data_in,
    output logic sdram_clk,sdram_cke,sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,
    output logic [1:0] sdram_dqm,sdram_ba,
    output logic [12:0] sdram_address,
    output logic [15:0] sdram_data_out,
    output logic sdram_data_oe,
    input logic DDRAM_BUSY,DDRAM_DOUT_READY,
    input logic [63:0] DDRAM_DOUT,
    output logic [7:0] DDRAM_BURSTCNT,DDRAM_BE,
    output logic [28:0] DDRAM_ADDR,
    output logic DDRAM_RD,DDRAM_WE,
    output logic [63:0] DDRAM_DIN
);
    wire core_reset=reset || !memory_initialized;
    logic tick,hblank,hsync,vsync;
    logic [11:0] x,y;
    logic [1:0] valid,ready,write,rsp,grant;
    logic [1:0][31:0] address,data,offset;
    logic [1:0][3:0] strobe,target;
    logic req_valid,req_ready,req_write,rsp_valid,rsp_error;
    logic [31:0] req_address,req_data,req_offset,rsp_data;
    logic [3:0] req_strobe,req_target;
    logic client;
    assign valid[0]=peer_valid;assign write[0]=0;assign address[0]=peer_address;assign data[0]=0;assign strobe[0]=4'hf;
    assign peer_ready=ready[0];assign peer_rsp_valid=rsp[0];assign peer_rsp_data=rsp_data;assign peer_rsp_error=rsp_error;
    always_comb begin
        req_target=0;req_offset=0;
        for(int i=0;i<2;i++) begin
            req_target|=target[i]&{4{grant[i]}};
            req_offset|=offset[i]&{32{grant[i]}};
        end
    end
    for(genvar i=0;i<2;i++) begin : decode
        cs_address_decode map(.address(address[i]),.flash_bank(3'b0),.target(target[i]),.offset(offset[i]));
    end
    cs_diagnostic_video raster(.clk,.reset(core_reset),.ce_pix(tick),
        .frame_start(),.hblank,.vblank,.hsync,.vsync,.rgb(),.pixel_x(x),.pixel_y(y));
    logic sb_valid,sb_ready,sb_done,fb_valid,fb_write,fb_region,fb_ready,fb_done;
    logic [17:0] sb_line,fb_line;
    logic [7:0][31:0] fb_wdata;
    logic [7:0][3:0] fb_wstrobe;
    vr0_scanout #(.LINE_BURST(SCAN_BURST)) scanout(.clk,.reset(core_reset),.restart(1'b0),
        .pixel_tick(tick),.display_enable(!hblank && !vblank),.screen_blank(1'b0),
        .hsync,.vsync,.hblank,.vblank,.pixel_x(x),.pixel_y(y),
        .visible_width(12'd320),.visible_height(12'd240),.display_address(gpu_display_address),
        .video_tick,.video_de,.video_hsync(),.video_vsync(),.video_hblank(),.video_vblank(),
        .video_x,.video_y,.video_r,.video_g,.video_b,.armed(video_armed),
        .underrun(video_underrun),.memory_fault(video_fault),.unsupported_geometry(),
        .fault_address(),.words_fetched(),.line_valid(),
        .req_valid(valid[1]),.req_ready(ready[1]),.req_address(address[1]),
        .req_data(data[1]),.req_strobe(strobe[1]),.req_write(write[1]),
        .rsp_valid(rsp[1]),.rsp_data,.rsp_error,
        .burst_valid(sb_valid),.burst_line(sb_line),.burst_ready(sb_ready),.burst_done(sb_done),.burst_rdata(gb_rdata));
    assign stat_scan_fetching=scanout.state!=0;
    cs_burst_mux burst_mux(.clk,.reset(core_reset),
        .a_valid(sb_valid),.a_region(1'b1),.a_line(sb_line),.a_ready(sb_ready),.a_done(sb_done),
        .b_valid(gb_valid),.b_write(gb_write),.b_region(gb_region),.b_line(gb_line),.b_wdata(gb_wdata),.b_wstrobe(gb_wstrobe),
        .b_ready(gb_ready),.b_done(gb_done),
        .burst_valid(fb_valid),.burst_write(fb_write),.burst_region(fb_region),.burst_line(fb_line),
        .burst_wdata(fb_wdata),.burst_wstrobe(fb_wstrobe),.burst_ready(fb_ready),.burst_done(fb_done));
    cs_bus_arbiter #(.CLIENTS(2),.PRIORITY_CLIENT(1),.PRIORITY_BURST(4),.REGISTER_GRANT(1)) arbiter(
        .clk,.reset(core_reset),.client_valid(valid),.client_ready(ready),
        .client_address(address),.client_data(data),.client_strobe(strobe),.client_write(write),
        .client_rsp_valid(rsp),.client_rsp_data(),.client_rsp_error(),
        .req_valid,.req_ready,.req_address,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,.req_client(client),.req_grant(grant));
    logic gb_valid,gb_write,gb_region,gb_ready,gb_done;
    logic [17:0] gb_line;
    logic [7:0][31:0] gb_wdata,gb_rdata;
    logic [7:0][3:0] gb_wstrobe;
    logic fabric_snoop_valid;
    logic [17:0] fabric_snoop_line;
    assign stat_gpu_state=gpu.state;assign stat_burst_start=gb_valid&&gb_ready;
    assign stat_burst_write=gb_write;assign stat_scan_valid=valid[1];assign stat_scan_ready=ready[1];assign stat_scan_rsp=rsp[1];assign stat_fill_b=gpu.fill_b;assign stat_advance=gpu.advance;assign stat_burst_line=gb_line;assign stat_pf_accept=gpu.pf_accept;assign stat_pf_used=gpu.state==10&&gpu.s10_stall&&gpu.use_alpha&&!gpu.tail_busy&&!gpu.wc_dirty&&gpu.pf_valid&&gpu.pf_line==gpu.s10_line;assign stat_write_stall=gpu.s10_stall;assign stat_be_bursting=memory.sdram.bursting;assign stat_be_burst_write=memory.sdram.burst_is_write;assign stat_be_burst_frame=memory.sdram.burst_base[24];assign stat_be_busy=memory.sdram.busy;
    assign stat_be_cmd_act=!sdram_cs_n && !sdram_ras_n && sdram_cas_n && sdram_we_n;assign stat_be_cmd_rw=!sdram_cs_n && sdram_ras_n && !sdram_cas_n;assign stat_pipe_fill=gpu.pipe_fill;assign stat_burst_region=gb_region;
    vr0_gpu #(.MAME_PALETTE_HACK(MAME_PALETTE_HACK),.SNOOP_COHERENT(1'b1)) gpu(.clk,.reset(core_reset),.reg_valid,.reg_ready,.reg_address,.reg_data,.reg_strobe,.reg_write,
        .reg_rsp_valid,.reg_rsp_data,.reg_rsp_error,.vblank(gpu_vblank),
        .req_valid(),.req_ready(1'b0),.req_address(),.req_data(),.req_strobe(),.req_write(),
        .rsp_valid(1'b0),.rsp_data(32'b0),.rsp_error(1'b0),
        .burst_valid(gb_valid),.burst_write(gb_write),.burst_region(gb_region),.burst_line(gb_line),
        .burst_wdata(gb_wdata),.burst_wstrobe(gb_wstrobe),.burst_ready(gb_ready),.burst_done(gb_done),
        .burst_error(1'b0),.burst_rdata(gb_rdata),
        .snoop_valid(bench_snoop_valid || fabric_snoop_valid),.snoop_line(bench_snoop_valid ? bench_snoop_line : fabric_snoop_line),
        .queue_front(gpu_queue_front),.queue_rear(gpu_queue_rear),.flip_count(),.display_bank(gpu_display_bank),
        .flip_sync(gpu_flip_sync),.busy(gpu_busy),.fault(gpu_fault),.display_address(gpu_display_address),
        .draw_address(gpu_draw_address),.fault_address(gpu_fault_address),
        .packets_completed(gpu_packets),.pixels_written(gpu_pixels));
    // Shorten the 24 MiB power-up clear/self-test; the bench loads memory after initialization.
    cs_memory_fabric #(.CLEAR_LAST(23'h0000fc),.TEST_LAST(14'h003f)) memory(.clk,.reset,.memory_initialized,
        .sdram_test_done(),.sdram_test_errors(),.sdram_test_first_addr(),.sdram_test_first_actual(),
        .req_valid,.req_ready,.req_target,.req_offset,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,
        .load_valid(1'b0),.load_ready(),.load_target(4'b0),.load_offset(32'b0),
        .load_data(64'b0),.load_be(8'b0),.load_done(),.load_error(),
        .backup_valid(1'b0),.backup_ready(),.backup_address(14'b0),.backup_data(32'b0),
        .backup_strobe(4'b0),.backup_write(1'b0),.backup_rsp_valid(),.backup_rsp_data(),
        .gpu_burst_valid(fb_valid),.gpu_burst_urgent(sb_valid),.gpu_burst_write(fb_write),.gpu_burst_region(fb_region),.gpu_burst_line(fb_line),
        .gpu_burst_wdata(fb_wdata),.gpu_burst_wstrobe(fb_wstrobe),.gpu_burst_ready(fb_ready),.gpu_burst_done(fb_done),
        .gpu_burst_rdata(gb_rdata),.gpu_snoop_valid(fabric_snoop_valid),.gpu_snoop_line(fabric_snoop_line),
        .sdram_capture_clk(clk),
        .sdram_data_in,.sdram_clk,.sdram_cke,.sdram_cs_n,.sdram_ras_n,.sdram_cas_n,.sdram_we_n,
        .sdram_dqm,.sdram_ba,.sdram_address,.sdram_data_out,.sdram_data_oe,
        .DDRAM_BUSY,.DDRAM_DOUT_READY,.DDRAM_DOUT,.DDRAM_BURSTCNT,.DDRAM_BE,
        .DDRAM_ADDR,.DDRAM_RD,.DDRAM_WE,.DDRAM_DIN);
endmodule
