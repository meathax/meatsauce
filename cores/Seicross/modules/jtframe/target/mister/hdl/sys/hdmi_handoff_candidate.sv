// Isolated experiment; not integrated into sys_top.
module seicro_hdmi_handoff_candidate(
 input wire clk_ctrl, clk_native, clk_scaler, reset, request_native, request_csync,
 input wire [26:0] native_tuple, scaler_tuple, input wire scaler_csync,
 output wire tx_clk, output wire [26:0] tx_tuple,
 output wire select_native, output wire switch_reset, local_reset
);
(* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] req_meta=0, req_sync=0;
always @(posedge clk_ctrl) begin req_meta<={request_native,request_csync}; req_sync<=req_meta; end
wire control_reset;
seicro_vga_reset_release ctl_release(clk_ctrl,reset,control_reset);
localparam BEFORE=2'd0, AFTER=2'd1, RUN=2'd2;
reg [1:0] state=BEFORE,count=0;
(* preserve, dont_merge *) reg [1:0] committed=2'b10;
assign select_native=committed[1];
wire committed_csync=committed[0];
assign switch_reset=control_reset | (state!=RUN);
always @(posedge clk_ctrl) if(!control_reset && state==BEFORE && count==3) committed<=req_sync;
always @(posedge clk_ctrl or posedge control_reset) begin
 if(control_reset) begin state<=BEFORE;count<=0;end
 else case(state)
  BEFORE: if(count==3)begin state<=AFTER;count<=0;end else count<=count+1'b1;
  AFTER: if(count==3)begin count<=0;state<=(req_sync==committed)?RUN:BEFORE;end else count<=count+1'b1;
  RUN: begin count<=0;if(req_sync!=committed)state<=BEFORE;end
  default: begin state<=BEFORE;count<=0;end
 endcase
end
wire selected_clk;
cyclonev_clkselect clk_mux(.clkselect({1'b1,select_native}),.inclk({clk_native,clk_scaler,2'b00}),.outclk(selected_clk));
seicro_vga_reset_release out_release(selected_clk,switch_reset,local_reset);
altddio_out #(.intended_device_family("Cyclone V"),.width(1)) clock_ddr(
 .datain_h(1'b0),.datain_l(1'b1),.outclock(selected_clk),.dataout(tx_clk),
 .aclr(local_reset),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
reg [26:0] native_cap=0, stage=0, outreg=0;
reg [3:0] valid=0;
reg outde=0;
always @(posedge selected_clk or posedge local_reset) begin
 if(local_reset) begin native_cap<=0;stage<=0;outreg<=0;valid<=0;outde<=0;end
 else begin
  if(select_native) native_cap<=native_tuple;
  stage<=select_native ? native_cap : {committed_csync?scaler_csync:scaler_tuple[26],scaler_tuple[25:0]};
  outreg<=stage;
  outde<=valid[2] ? stage[24] : 1'b0;
  valid<={valid[2:0],1'b1};
 end
end
// Tuple bit 24 is DE. Quiesce it immediately on a switch; publish only after
// four selected-clock edges after local reset release.
assign tx_tuple={outreg[26:25],outde,outreg[23:0]};
endmodule
