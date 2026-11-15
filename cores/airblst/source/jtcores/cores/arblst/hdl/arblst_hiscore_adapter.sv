// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical MAME readiness is latched once per reset/profile/config epoch.
// Later earned scores may legitimately change the marker bytes.
module arblst_hiscore_adapter #(parameter [17:0] PROBE_WAIT=18'h3ffff)(input wire clk,reset,clear_config,paused,autosave,
input wire ioctl_upload,ioctl_download,ioctl_wr,input wire [24:0] ioctl_addr,input wire [7:0] ioctl_index,ioctl_dout,
input wire osd_open,input wire state_grant,input wire [7:0] state_dout,
output wire upload_req,configured,pause_cpu,state_req,state_we,epoch_ready,
output wire [23:0] state_addr,output wire [7:0] state_din,ioctl_din);
reg [2:0] probe=0;reg [17:0] probe_delay=0;reg ready=0;
wire [23:0] first_addr=profile?24'hf018cd:24'hf014e6;
wire [23:0] last_addr=profile?24'hf01957:24'hf01571;
wire [7:0] first_value=8'h00,last_value=8'h14;
wire config_download=ioctl_download && ioctl_index==8'd3;
reg last_config_download=0;
reg [31:0] config_base=0;
reg [7:0] config_length=0,config_first=0,config_last=0;
wire config_begin=config_download && !last_config_download;
wire epoch_clear=clear_config || config_begin;
wire profile=config_base==32'h00f018cd;
wire profile_valid=(profile && config_length==8'd139 ||
    config_base==32'h00f014e6 && config_length==8'd140) && config_first==0 && config_last==8'h14;
always @(posedge clk)begin
 last_config_download<=config_download;
 if(epoch_clear)begin config_base<=0;config_length<=0;config_first<=0;config_last<=0;end
 if(config_download && ioctl_wr)case(ioctl_addr)
  25'd16:config_base[31:24]<=ioctl_dout;
  25'd17:config_base[23:16]<=ioctl_dout;
  25'd18:config_base[15:8]<=ioctl_dout;
  25'd19:config_base[7:0]<=ioctl_dout;
  25'd20:config_length<=ioctl_dout;
  25'd21:config_first<=ioctl_dout;
  25'd22:config_last<=ioctl_dout;
  default:;
 endcase
end
wire probe_active=probe!=0;
always @(posedge clk)begin
 if(reset||epoch_clear)begin probe<=0;probe_delay<=0;ready<=0;end
 else if(!ready && configured && profile_valid && !config_download)case(probe)
 0:if(probe_delay==0)probe<=1;else probe_delay<=probe_delay-18'd1;
 1:if(state_grant)probe<=2;
 2:if(state_grant)begin if(state_dout==first_value)probe<=3;else begin probe<=0;probe_delay<=PROBE_WAIT;end end
 3:if(state_grant)probe<=4;
 4:if(state_grant)begin ready<=state_dout==last_value;probe<=0;probe_delay<=PROBE_WAIT;end
 default:probe<=0;
 endcase
end
wire reading,writing,hs_pause,hs_write;wire [23:0] hs_addr;wire [7:0] hs_data;
wire hs_req=reading||writing;
assign epoch_ready=ready;
assign state_req=probe_active||(ready&&hs_req);
assign state_we=ready&&!probe_active&&hs_write&&!reset&&!epoch_clear;
assign state_addr=probe_active?(probe<3?first_addr:last_addr):hs_addr;
assign state_din=hs_data;
assign pause_cpu=probe_active||hs_pause;
pwb_hiscore #(.HS_ADDRESSWIDTH(24),.RAM_READ_LATENCY(1)) u_hiscore(
.clk(clk),.reset(reset||!ready),.clear_config(epoch_clear),.ram_grant(state_grant&&ready),
.paused(paused&&(!hs_req||state_grant)),.autosave(autosave),
.ioctl_upload(ioctl_upload),.ioctl_upload_req(upload_req),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.OSD_STATUS(osd_open&&ready),.data_from_hps(ioctl_dout),.data_from_ram(state_dout),
.ram_address(hs_addr),.data_to_hps(ioctl_din),.data_to_ram(hs_data),.ram_write(hs_write),
.ram_intent_read(reading),.ram_intent_write(writing),.pause_cpu(hs_pause),.configured(configured));
endmodule
