// SPDX-License-Identifier: GPL-3.0-or-later
// Passive diagnostic snapshots; stopped source clocks do not block the host.
module spinal_diag_mailbox #(parameter W=256)(input clk_src,clk_sys,request,
 input [W-1:0] live_data,output reg [W-1:0] captured=0,output reg valid=0,output wire pending);
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg[1:0] req_sync=0,ack_sync=0;
 reg req=0,ack=0,busy=0;reg[1:0]settle=0;
 (* preserve *) reg[W-1:0] held=0;
 always @(posedge clk_src)begin
  req_sync<={req_sync[0],req};
  if(req_sync[1]!=ack)begin held<=live_data;ack<=req_sync[1];end
 end
 assign pending=busy;
 always @(posedge clk_sys)begin
  ack_sync<={ack_sync[0],ack};
  if(request && !busy)begin req<=~req;busy<=1;settle<=0;end
  if(busy && ack_sync[1]==req)begin
   if(settle==2)begin captured<=held;valid<=1;busy<=0;settle<=0;end
   else settle<=settle+1'b1;
  end
 end
endmodule

module spinal_diag_raster(input clk,hs,vs,de,pixel_ce,input[23:0]rgb,output[255:0]metrics,output[11:0]x);
 reg[31:0]ticks=0;reg[15:0]frames=0,hcnt=0,hperiod=0,hwidth=0,hs_count=0;
 reg[15:0]lines=0,last_lines=0,active_lines=0,last_active_lines=0,dewidth=0,last_dewidth=0;
 reg[23:0]vcycles=0,last_vcycles=0,depixels=0,last_depixels=0;
 reg[15:0]hmin=16'hffff,hmax=0,crc=16'h1,last_crc=0;
 reg oh=0,ov=0,od=0;reg[7:0]seen=0;
 assign x=hcnt[11:0];
 always @(posedge clk)begin
  ticks<=ticks+1'b1;hcnt<=hcnt+1'b1;vcycles<=vcycles+1'b1;
  oh<=hs;ov<=vs;od<=de;
  seen<=seen|{(rgb!=0 && de),(&vcycles),(&hcnt),(&depixels),1'b0,de,vs,hs};
  if(hs)hs_count<=hs_count+1'b1;
  if(!hs && oh)begin hwidth<=hs_count;hs_count<=0;end
  if(hs && !oh)begin
   hperiod<=hcnt+1'b1;hcnt<=0;lines<=lines+1'b1;
   if(frames!=0)begin if(hcnt+1'b1<hmin)hmin<=hcnt+1'b1;if(hcnt+1'b1>hmax)hmax<=hcnt+1'b1;end
  end
  if(de && pixel_ce)begin depixels<=depixels+1'b1;dewidth<=dewidth+1'b1;
   crc<={crc[14:0],crc[15]^crc[13]^crc[12]^crc[10]^ (^rgb)};
  end
  if(!de && od)begin last_dewidth<=dewidth;dewidth<=0;active_lines<=active_lines+1'b1;end
  if(vs && !ov)begin
   frames<=frames+1'b1;last_lines<=lines+(hs&&!oh);lines<=0;
   last_vcycles<=vcycles+1'b1;vcycles<=0;last_depixels<=depixels;depixels<=0;
   last_active_lines<=active_lines;active_lines<=0;last_crc<=crc;crc<=16'h1;
  end
 end
 assign metrics={last_crc,seen,4'b0,de,vs,hs,oh,hmax,hmin,last_active_lines,last_dewidth,
  8'b0,last_depixels,seen,last_vcycles,hwidth,hperiod,frames,last_lines,ticks};
endmodule

// Read-only data plane plus explicit opt-in pattern controls. Normal mode is zero.
module spinal_video_diagnostic(input clk_sys,clk_native,clk_scaled,clk_final,clk_ref,
 input nh,nv,nd,nce,sh,sv,sd,fh,fv,fd,input[23:0]nrgb,srgb,frgb,
 input io_uio,io_strobe,input[15:0]io_din,input[15:0]cfg_word,input[31:0]status,
 input[11:0]width,hfp,hbp,height,vfp,vbp,input[12:0]hs,vs,
 input pll_write,pll_wait,pll_ready,pll_locked,input[5:0]pll_address,input[31:0]pll_data,
 input mem_read,mem_write,mem_wait,mem_valid,
 output reg[15:0]reply=0,output reg force_apply=0,output reg[1:0]pattern=0,output reg[1:0]active_pattern=0,output[6:0]summary,
 output reg pattern_hs=0,pattern_vs=0,pattern_de=0,output reg[23:0]pattern_rgb=0);
 reg mode_toggle=0,mode_ack=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg[1:0]mode_ack_sync=0;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg[2:0]mode_sync=0;
 reg[97:0]geometry_held=0;reg[97:0]geometry_active=0;
 wire[11:0]pw,pfp,pbp,ph,pvfp,pvbp;wire[12:0]phs,pvs;
 assign {pvs,phs,pvbp,pvfp,ph,pbp,pfp,pw}=geometry_active;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg[1:0]lock_ref_sync=0;
 always @(posedge clk_ref)lock_ref_sync<={lock_ref_sync[0],pll_locked};
 wire[255:0]live0,live1,live2;wire[255:0]bank0,bank1,bank2;
 wire[191:0]bank3;wire[11:0]nx,sx,fx;
 reg request=0;wire[3:0]valid,pending;
 spinal_diag_raster native_meter(clk_native,nh,nv,nd,nce,nrgb,live0,nx);
 spinal_diag_raster scaler_meter(clk_scaled,sh,sv,sd,1'b1,srgb,live1,sx);
 spinal_diag_raster final_meter(clk_final,fh,fv,fd,1'b1,frgb,live2,fx);
 spinal_diag_mailbox m0(clk_native,clk_sys,request,live0,bank0,valid[0],pending[0]);
 spinal_diag_mailbox m1(clk_scaled,clk_sys,request,live1,bank1,valid[1],pending[1]);
 spinal_diag_mailbox m2(clk_final,clk_sys,request,live2,bank2,valid[2],pending[2]);
 reg[31:0]last_k=0;reg[31:0]last_m=0,last_n=0,last_c=0;reg[15:0]writes=0,commits=0;
 reg[7:0]pll_flags=0;
 always @(posedge clk_ref)begin
  pll_flags<=pll_flags|{4'b0,lock_ref_sync[1],pll_ready,pll_wait,pll_write};
  if(pll_write&&!pll_wait)begin
   writes<=writes+1'b1;
   case(pll_address) 3:last_n<=pll_data;4:last_m<=pll_data;
    5:last_c<=pll_data;7:last_k<=pll_data;2:commits<=commits+1'b1;endcase
  end
 end
 wire[191:0]pll_live={16'b0,pll_flags,8'b0,commits,writes,last_c,last_n,last_m,last_k};
 spinal_diag_mailbox #(.W(192)) m3(clk_ref,clk_sys,request,pll_live,bank3,valid[3],pending[3]);
 reg[31:0]sys_ticks=0,snapshot_time=0;reg[15:0]snapshot_seq=0;
 reg[15:0]reads=0,returns=0;reg[7:0]cmd=0,count=0;reg has_cmd=0;
 reg[10:0]index=0;reg[8:0]trace_count=0;
 (* ramstyle="M10K" *) reg[63:0]trace[0:255];
 reg[63:0]trace_q;
 always @(posedge clk_sys)trace_q<=trace[index[9:2]];
 assign summary={1'b1,valid[2:0],pending[2:0]};
 reg[15:0]read_word;
 always @*begin
  read_word=0;
  case(index)
   0:read_word=16'h5344;1:read_word=16'h0201;2:read_word={8'b0,valid,pending};
   3:read_word=snapshot_seq;4:read_word=snapshot_time[15:0];5:read_word=snapshot_time[31:16];
   6:read_word=status[15:0];7:read_word=status[31:16];8:read_word={7'b0,trace_count};
   9:read_word={12'b0,(mode_toggle!=mode_ack_sync[1]),mode_ack_sync[1],pattern};10:read_word=reads;11:read_word=returns;
   12:read_word=sys_ticks[15:0];13:read_word=sys_ticks[31:16];
   14:read_word={4'b0,width};15:read_word={4'b0,height};
   64:read_word={4'b0,hfp};65:read_word={4'b0,hbp};66:read_word={3'b0,hs};
   67:read_word={4'b0,vfp};68:read_word={4'b0,vbp};69:read_word={3'b0,vs};70:read_word=cfg_word;
   72:read_word=geometry_held[15:0];73:read_word=geometry_held[31:16];
   74:read_word=geometry_held[47:32];75:read_word=geometry_held[63:48];
   76:read_word=geometry_held[79:64];77:read_word=geometry_held[95:80];78:read_word={14'b0,geometry_held[97:96]};
   default:begin
    if(index>=16 && index<32)read_word=bank0[index[3:0]*16+:16];
    if(index>=32 && index<48)read_word=bank1[index[3:0]*16+:16];
    if(index>=48 && index<64)read_word=bank2[index[3:0]*16+:16];
    if(index>=80 && index<92)read_word=bank3[(index-80)*16+:16];
    if(index>=1024)read_word=trace_q[index[1:0]*16+:16];
   end
  endcase
 end
 always @(posedge clk_sys)begin
  sys_ticks<=sys_ticks+1'b1;request<=0;force_apply<=0;
  if(mem_read&&!mem_wait)reads<=reads+1'b1;
  if(mem_valid)returns<=returns+1'b1;
  if(!io_uio)begin has_cmd<=0;count<=0;reply<=0;end
  else if(io_strobe)begin
   reply<=0;
   if(!has_cmd)begin has_cmd<=1;cmd<=io_din[7:0];count<=0;
    if(io_din[7:0]==8'h5a)reply<=16'h5344;
   end else begin
    count<=count+1'b1;
    if(cmd==8'h5a)begin if(count==0)index<=io_din[10:0];else reply<=read_word;end
    if(cmd==8'h5b && count==0)begin
     if(io_din[14])force_apply<=1;
     if(io_din[0])begin request<=1;snapshot_time<=sys_ticks;snapshot_seq<=snapshot_seq+1'b1;end
     if(io_din[15] && mode_toggle==mode_ack_sync[1])begin pattern<=io_din[5:4];geometry_held<={vs,hs,vbp,vfp,height,hbp,hfp,width};mode_toggle<=~mode_toggle;end
    end
   end
   if(trace_count<256 && ((has_cmd&&(cmd==1||cmd==8'h20))||(!has_cmd&&(io_din[7:0]==1||io_din[7:0]==8'h20))))begin
    trace[trace_count[7:0]]<={sys_ticks[23:0],has_cmd?cmd:io_din[7:0],io_din,7'b0,has_cmd,count};
    trace_count<=trace_count+1'b1;
   end
  end
 end
 // Source value is held until ACK returns; stopped destination preserves pending request.
 always @(posedge clk_sys)mode_ack_sync<={mode_ack_sync[0],mode_ack};
 // Geometry arithmetic is staged: one12-bit addition per HDMI transfer.
 reg[1:0]mode_state=0,requested_mode=0;reg geometry_ready=0;
 reg[11:0]hstart=0,vstart=0,hpad=0,vpad=0,hend=0,vend=0,htotal=0,vtotal=0;
 always @(posedge clk_scaled)begin
  mode_sync<={mode_sync[1:0],mode_toggle};
  case(mode_state)
   0:if(mode_sync[2]!=mode_ack)begin geometry_active<=geometry_held;requested_mode<=pattern;geometry_ready<=0;mode_state<=1;end
   1:begin hstart<=pw+pfp;vstart<=ph+pvfp;hpad<=pbp+phs[11:0];vpad<=pvbp+pvs[11:0];mode_state<=2;end
   2:begin hend<=hstart+phs[11:0];vend<=vstart+pvs[11:0];htotal<=hstart+hpad;vtotal<=vstart+vpad;mode_state<=3;end
   3:begin active_pattern<=requested_mode;mode_ack<=mode_sync[2];geometry_ready<=1;mode_state<=0;end
  endcase
 end
 reg[11:0]px=0,py=0;
 always @(posedge clk_scaled)begin
  if(!geometry_ready || mode_state!=0)begin px<=0;py<=0;end
  else if(px+1>=htotal)begin px<=0;if(py+1>=vtotal)py<=0;else py<=py+1'b1;end
  else px<=px+1'b1;
 end
 wire[11:0]color_x=(active_pattern==3)?px:sx;
 // One shared output stage preserves the complete pattern tuple alignment.
 always @(posedge clk_scaled)begin
  pattern_hs<=geometry_ready && px>=hstart && px<hend;
  // Match ascal OSWEEP: both VS edges coincide with HS start.
  if(!geometry_ready || mode_state!=0)pattern_vs<=0;
  else if(px==hstart)begin
   if(py==vstart)pattern_vs<=1;
   else if(py==vend)pattern_vs<=0;
  end
  pattern_de<=geometry_ready && px<pw && py<ph;
  pattern_rgb<={{8{color_x[8]}},{8{color_x[7]}},{8{color_x[6]}}};
 end
 // Export only the destination-held mode to the HDMI domain through separate port use.
endmodule
