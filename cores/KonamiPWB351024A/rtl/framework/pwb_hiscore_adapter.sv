// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical MAME readiness is latched once per reset/profile/config epoch.
// Later earned scores may legitimately change the marker bytes.
module pwb_hiscore_adapter #(parameter [17:0] PROBE_WAIT=18'h3ffff)(input wire clk,reset,clear_config,profile,paused,autosave,
input wire ioctl_upload,ioctl_download,ioctl_wr,input wire [24:0] ioctl_addr,input wire [7:0] ioctl_index,ioctl_dout,
input wire osd_open,input wire state_grant,input wire [7:0] state_dout,
output wire upload_req,configured,pause_cpu,state_req,state_we,epoch_ready,
output wire [15:0] state_addr,output wire [7:0] state_din,ioctl_din);
reg [2:0] probe=0;reg [17:0] probe_delay=0;reg ready=0;
wire [15:0] first_addr=profile?16'h415d:16'h41c4;
wire [15:0] last_addr=profile?16'h41a1:16'h41f1;
wire [7:0] first_value=profile?8'hae:8'h01,last_value=profile?8'h77:8'h01;
wire probe_active=probe!=0;
always @(posedge clk)begin
 if(reset||clear_config)begin probe<=0;probe_delay<=0;ready<=0;end
 else if(!ready)case(probe)
 0:if(probe_delay==0)probe<=1;else probe_delay<=probe_delay-18'd1;
 1:if(state_grant)probe<=2;
 2:if(state_grant)begin if(state_dout==first_value)probe<=3;else begin probe<=0;probe_delay<=PROBE_WAIT;end end
 3:if(state_grant)probe<=4;
 4:if(state_grant)begin ready<=state_dout==last_value;probe<=0;probe_delay<=PROBE_WAIT;end
 default:probe<=0;
 endcase
end
wire reading,writing,hs_pause,hs_write;wire [15:0] hs_addr;wire [7:0] hs_data;
wire hs_req=reading||writing;
assign epoch_ready=ready;
assign state_req=probe_active||(ready&&hs_req);
assign state_we=ready&&!probe_active&&hs_write;
assign state_addr=probe_active?(probe<3?first_addr:last_addr):hs_addr;
assign state_din=hs_data;
assign pause_cpu=probe_active||hs_pause;
pwb_hiscore #(.HS_ADDRESSWIDTH(16),.RAM_READ_LATENCY(1)) u_hiscore(
.clk(clk),.reset(reset||!ready),.clear_config(clear_config),.ram_grant(state_grant&&ready),
.paused(paused&&(!hs_req||state_grant)),.autosave(autosave),
.ioctl_upload(ioctl_upload),.ioctl_upload_req(upload_req),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index),.OSD_STATUS(osd_open&&ready),.data_from_hps(ioctl_dout),.data_from_ram(state_dout),
.ram_address(hs_addr),.data_to_hps(ioctl_din),.data_to_ram(hs_data),.ram_write(hs_write),
.ram_intent_read(reading),.ram_intent_write(writing),.pause_cpu(hs_pause),.configured(configured));
endmodule
