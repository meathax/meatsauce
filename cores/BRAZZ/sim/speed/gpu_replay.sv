// SPDX-License-Identifier: GPL-3.0-or-later
// Speed-check bench: real vr0_gpu (line-burst port) + live vr0_scanout + CPU-like peer through
// the board's registered-grant arbiter, the real cs_memory_fabric and SDRAM controller.
// Replays one MAME-captured game frame's packet list and measures render clocks.
module cs_gpu_replay #(parameter bit MAME_PALETTE_HACK=1) (
    input logic clk,reset,
    input logic peer_valid,peer_write,
    input logic [31:0] peer_address,
    output logic peer_ready,peer_rsp_valid,
    output logic peer_rsp_error,
    input logic reg_valid,reg_write,
    input logic [15:0] reg_address,
    input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,
    output logic reg_ready,reg_rsp_valid,
    output logic gpu_busy,gpu_fault,gpu_flip_sync,
    output logic [10:0] gpu_queue_front,gpu_queue_rear,
    output logic [31:0] gpu_packets,gpu_pixels,
    output logic [4:0] gpu_state,
    output logic gb_valid_o,gb_ready_o,gb_done_o,
    output logic memory_initialized,video_tick,video_de,video_armed,video_underrun,video_fault,
    output logic [11:0] video_x,video_y,
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
    logic tick,hblank,vblank,hsync,vsync;
    logic [11:0] x,y;
    logic [1:0] valid,ready,write,rsp,grant;
    logic [1:0][31:0] address,data,offset;
    logic [1:0][3:0] strobe,target;
    logic req_valid,req_ready,req_write,rsp_valid,rsp_error;
    logic [31:0] req_address,req_data,req_offset,rsp_data;
    logic [3:0] req_strobe,req_target;
    logic client;
    logic [22:0] display_address;
    assign valid[0]=peer_valid;assign write[0]=peer_write;assign address[0]=peer_address;assign data[0]=32'h5a5a5a5a;assign strobe[0]=4'hf;
    assign peer_ready=ready[0];assign peer_rsp_valid=rsp[0];assign peer_rsp_error=rsp_error;
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
    vr0_scanout scanout(.clk,.reset(core_reset),.restart(1'b0),
        .pixel_tick(tick),.display_enable(!hblank && !vblank),.screen_blank(1'b0),
        .hsync,.vsync,.hblank,.vblank,.pixel_x(x),.pixel_y(y),
        .visible_width(12'd320),.visible_height(12'd240),.display_address,
        .video_tick,.video_de,.video_hsync(),.video_vsync(),.video_hblank(),.video_vblank(),
        .video_x,.video_y,.video_r(),.video_g(),.video_b(),.armed(video_armed),
        .underrun(video_underrun),.memory_fault(video_fault),.unsupported_geometry(),
        .fault_address(),.words_fetched(),.line_valid(),
        .req_valid(valid[1]),.req_ready(ready[1]),.req_address(address[1]),
        .req_data(data[1]),.req_strobe(strobe[1]),.req_write(write[1]),
        .rsp_valid(rsp[1]),.rsp_data,.rsp_error);
    cs_bus_arbiter #(.CLIENTS(2),.PRIORITY_CLIENT(1),.REGISTER_GRANT(1)) arbiter(
        .clk,.reset(core_reset),.client_valid(valid),.client_ready(ready),
        .client_address(address),.client_data(data),.client_strobe(strobe),.client_write(write),
        .client_rsp_valid(rsp),.client_rsp_data(),.client_rsp_error(),
        .req_valid,.req_ready,.req_address,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,.req_client(client),.req_grant(grant));
    logic gb_valid,gb_write,gb_region,gb_ready,gb_done;
    logic [17:0] gb_line;
    logic [7:0][31:0] gb_wdata,gb_rdata;
    logic [7:0][3:0] gb_wstrobe;
    assign gb_valid_o=gb_valid;assign gb_ready_o=gb_ready;assign gb_done_o=gb_done;
    assign gpu_state=gpu.state;
    vr0_gpu #(.MAME_PALETTE_HACK(MAME_PALETTE_HACK)) gpu(.clk,.reset(core_reset),.reg_valid,.reg_ready,.reg_address,.reg_data,.reg_strobe,.reg_write,
        .reg_rsp_valid,.reg_rsp_data(),.reg_rsp_error(),.vblank(1'b0),
        .req_valid(),.req_ready(1'b0),.req_address(),.req_data(),.req_strobe(),.req_write(),
        .rsp_valid(1'b0),.rsp_data(32'b0),.rsp_error(1'b0),
        .burst_valid(gb_valid),.burst_write(gb_write),.burst_region(gb_region),.burst_line(gb_line),
        .burst_wdata(gb_wdata),.burst_wstrobe(gb_wstrobe),.burst_ready(gb_ready),.burst_done(gb_done),
        .burst_error(1'b0),.burst_rdata(gb_rdata),
        .queue_front(gpu_queue_front),.queue_rear(gpu_queue_rear),.flip_count(),.display_bank(),
        .flip_sync(gpu_flip_sync),.busy(gpu_busy),.fault(gpu_fault),.display_address,
        .draw_address(),.fault_address(),
        .packets_completed(gpu_packets),.pixels_written(gpu_pixels));
    cs_memory_fabric #(.CLEAR_LAST(23'h0000fc),.TEST_LAST(14'h003f)) memory(.clk,.reset,.memory_initialized,
        .sdram_test_done(),.sdram_test_errors(),.sdram_test_first_addr(),.sdram_test_first_actual(),
        .req_valid,.req_ready,.req_target,.req_offset,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,
        .load_valid(1'b0),.load_ready(),.load_target(4'b0),.load_offset(32'b0),
        .load_data(64'b0),.load_be(8'b0),.load_done(),.load_error(),
        .backup_valid(1'b0),.backup_ready(),.backup_address(14'b0),.backup_data(32'b0),
        .backup_strobe(4'b0),.backup_write(1'b0),.backup_rsp_valid(),.backup_rsp_data(),
        .gpu_burst_valid(gb_valid),.gpu_burst_write(gb_write),.gpu_burst_region(gb_region),.gpu_burst_line(gb_line),
        .gpu_burst_wdata(gb_wdata),.gpu_burst_wstrobe(gb_wstrobe),.gpu_burst_ready(gb_ready),.gpu_burst_done(gb_done),
        .gpu_burst_rdata(gb_rdata),
        .sdram_capture_clk(clk),
        .sdram_data_in,.sdram_clk,.sdram_cke,.sdram_cs_n,.sdram_ras_n,.sdram_cas_n,.sdram_we_n,
        .sdram_dqm,.sdram_ba,.sdram_address,.sdram_data_out,.sdram_data_oe,
        .DDRAM_BUSY,.DDRAM_DOUT_READY,.DDRAM_DOUT,.DDRAM_BURSTCNT,.DDRAM_BE,
        .DDRAM_ADDR,.DDRAM_RD,.DDRAM_WE,.DDRAM_DIN);
endmodule
