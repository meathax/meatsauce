// SPDX-License-Identifier: GPL-3.0-or-later
// Diagnostic only: actual scanout/arbiter/physical fabric under bounded peer load.
// The timing generator supplies game geometry; its diagnostic RGB is unused.
module cs_scanout_load #(parameter DISPLAY_PRIORITY=0) (
    input logic clk,reset,
    input logic [1:0] peer_valid,peer_write,
    input logic [1:0][31:0] peer_address,peer_data,
    input logic [1:0][3:0] peer_strobe,
    output logic [1:0] peer_ready,peer_rsp_valid,
    output logic [31:0] peer_rsp_data,
    output logic peer_rsp_error,
    output logic memory_initialized,video_tick,video_de,video_armed,video_underrun,video_fault,
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
    logic tick,hblank,vblank,hsync,vsync;
    logic [11:0] x,y;
    logic [2:0] valid,ready,write,rsp,grant;
    logic [2:0][31:0] address,data,offset;
    logic [2:0][3:0] strobe,target;
    logic req_valid,req_ready,req_write,rsp_valid,rsp_error;
    logic [31:0] req_address,req_data,req_offset,rsp_data;
    logic [3:0] req_strobe,req_target;
    logic [1:0] client;
    assign valid[1:0]=peer_valid;assign write[1:0]=peer_write;
    assign address[1:0]=peer_address;assign data[1:0]=peer_data;assign strobe[1:0]=peer_strobe;
    assign peer_ready=ready[1:0];assign peer_rsp_valid=rsp[1:0];
    assign peer_rsp_data=rsp_data;assign peer_rsp_error=rsp_error;
    always_comb begin
        req_target=0;req_offset=0;
        for(int i=0;i<3;i++) begin
            req_target|=target[i]&{4{grant[i]}};
            req_offset|=offset[i]&{32{grant[i]}};
        end
    end
    for(genvar i=0;i<3;i++) begin : decode
        cs_address_decode map(.address(address[i]),.flash_bank(3'b0),
            .target(target[i]),.offset(offset[i]));
    end
    cs_diagnostic_video raster(.clk,.reset(core_reset),.ce_pix(tick),
        .frame_start(),.hblank,.vblank,.hsync,.vsync,.rgb(),.pixel_x(x),.pixel_y(y));
    vr0_scanout scanout(.clk,.reset(core_reset),.restart(1'b0),
        .pixel_tick(tick),.display_enable(!hblank && !vblank),.screen_blank(1'b0),
        .hsync,.vsync,.hblank,.vblank,.pixel_x(x),.pixel_y(y),
        .visible_width(12'd320),.visible_height(12'd240),.display_address(23'd0),
        .video_tick,.video_de,.video_hsync(),.video_vsync(),.video_hblank(),.video_vblank(),
        .video_x,.video_y,.video_r,.video_g,.video_b,.armed(video_armed),
        .underrun(video_underrun),.memory_fault(video_fault),.unsupported_geometry(),
        .fault_address(),.words_fetched(),.line_valid(),
        .req_valid(valid[2]),.req_ready(ready[2]),.req_address(address[2]),
        .req_data(data[2]),.req_strobe(strobe[2]),.req_write(write[2]),
        .rsp_valid(rsp[2]),.rsp_data,.rsp_error);
    cs_bus_arbiter #(.CLIENTS(3),.PRIORITY_CLIENT(DISPLAY_PRIORITY?2:-1)) arbiter(
        .clk,.reset(core_reset),.client_valid(valid),.client_ready(ready),
        .client_address(address),.client_data(data),.client_strobe(strobe),.client_write(write),
        .client_rsp_valid(rsp),.client_rsp_data(),.client_rsp_error(),
        .req_valid,.req_ready,.req_address,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,.req_client(client),.req_grant(grant));
    // Bandwidth bench: shorten the 24 MiB power-up clear/self-test (as the memory_fabric test does).
    cs_memory_fabric #(.CLEAR_LAST(23'h0000fc),.TEST_LAST(14'h003f)) memory(.clk,.reset,.memory_initialized,
        .req_valid,.req_ready,.req_target,.req_offset,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error,
        .load_valid(1'b0),.load_ready(),.load_target(4'b0),.load_offset(32'b0),
        .load_data(64'b0),.load_be(8'b0),.load_done(),.load_error(),
        .backup_valid(1'b0),.backup_ready(),.backup_address(14'b0),.backup_data(32'b0),
        .backup_strobe(4'b0),.backup_write(1'b0),.backup_rsp_valid(),.backup_rsp_data(),
        .sdram_data_in,.sdram_clk,.sdram_cke,.sdram_cs_n,.sdram_ras_n,.sdram_cas_n,.sdram_we_n,
        .sdram_dqm,.sdram_ba,.sdram_address,.sdram_data_out,.sdram_data_oe,
        .DDRAM_BUSY,.DDRAM_DOUT_READY,.DDRAM_DOUT,.DDRAM_BURSTCNT,.DDRAM_BE,
        .DDRAM_ADDR,.DDRAM_RD,.DDRAM_WE,.DDRAM_DIN);
endmodule
