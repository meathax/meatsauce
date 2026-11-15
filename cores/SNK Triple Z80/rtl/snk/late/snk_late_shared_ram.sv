// Single game clock. Both CPUs share one scheduled RAM port; video uses
// independent bank ports. CPU read responses have at most three master edges
// of latency (request slot, synchronous RAM, tagged response).
module snk_late_shared_ram #(parameter HISCORE_ENABLE=0)(
 input wire [7:0] profile_id,
 input wire clk,reset_n,
 input wire hs_grant,hs_req,hs_write,
 input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 output wire hs_ack,output wire [7:0] hs_rdata,

 input wire a_req,b_req,a_write,b_write,
 input wire [13:0] a_offset,b_offset,
 input wire [7:0] a_data,b_data,
 output reg [7:0] a_q,b_q,
 input wire [10:0] vbg_addr,vtx_addr,output reg [7:0] vbg_data,vtx_data,
 input wire [6:0] vspr_addr,output reg [31:0] vspr_data,
 input wire [3:0] turbo_select,
 input wire [8:0] turbo_x,turbo_y,output wire [7:0] turbo_data
);
 wire granted=HISCORE_ENABLE && hs_grant;
 wire ik=profile_id==8'd14 || profile_id==8'd18;
 wire late_valid=profile_id==8'd11 || profile_id==8'd12 || profile_id==8'd13 || profile_id==8'd16 || profile_id==8'd19 || ik;
 wire profile_range_valid;
 snk_hiscore_contract whitelist(.profile(profile_id),.descriptor_addr(8'd0),.ram_addr(hs_addr),
 .descriptor_data(),.descriptor_bytes(),.dump_bytes(),.supported(),.range_valid(profile_range_valid));
 wire hs_address_ok=late_valid && profile_range_valid;
 reg hs_inflight,hs_pending,hs_ack_i;reg [7:0] hs_rdata_i;
 wire hs_accept=granted && hs_req && hs_address_ok && !hs_inflight;
 wire [13:0] hs_offset=hs_addr-16'hd000;
 assign hs_ack=HISCORE_ENABLE ? hs_ack_i : 1'b0;
 assign hs_rdata=HISCORE_ENABLE ? hs_rdata_i : 8'd0;
 reg turn;
 wire selected = a_write  ?  1'b0:(b_write  ?  1'b1:turn);
 wire selected_req=!granted && (selected ? b_req:a_req);
 wire selected_write=hs_accept ? hs_write : (!granted && (selected ? b_write:a_write));
 wire [13:0] offset=hs_accept ? hs_offset : (selected ? b_offset:a_offset);
 wire [7:0] data=hs_accept ? hs_wdata : (selected ? b_data:a_data);
 // ikari/victroad: D800-DFFF is a mirror of the bg RAM (D000-D7FF), not separate shared RAM
 // Decode the 2 KiB regions from the upper address page. Full-width range
 // comparators here sat on the sprite RAM write-enable path; these page
 // comparisons preserve the exact 0000-3fff map with a shallower decode.
 reg [1:0] bank;
 always @* begin
  case(offset[13:11])
   3'd0: bank=2'd0;                    // 0000-07ff: background RAM
   3'd1: bank=ik ? 2'd0 : 2'd1;        // 0800-0fff: shared RAM or Ikari mirror
   3'd2,3'd3,3'd4: bank=2'd2;          // 1000-27ff: sprite RAM
   default: bank=2'd3;                 // 2800-3fff: text RAM
  endcase
 end
 wire [12:0] spr_index=bank==2'd2  ?  offset[12:0]-13'h1000:13'd0;
 reg [7:0] bg_memory[0:2047],shared_memory[0:2047],sprite_work[0:6143],text_memory[0:2047];
 reg [7:0] q_bg,q_shared,q_sprite,q_text;
 reg last_selected,last_valid;
 reg [1:0] last_bank;
 always @(posedge clk) begin
  q_bg<=bg_memory[offset[10:0]];
  q_shared<=shared_memory[offset[10:0]];
  q_sprite<=sprite_work[spr_index];
  q_text<=text_memory[offset[10:0]];
  if(reset_n&&selected_write) begin
   case(bank)
    2'd0:bg_memory[offset[10:0]]<=data;
    2'd1:shared_memory[offset[10:0]]<=data;
    2'd2:sprite_work[spr_index]<=data;
    2'd3:text_memory[offset[10:0]]<=data;
   endcase
  end
 end
 always @(posedge clk) begin
  vbg_data<=bg_memory[vbg_addr];vtx_data<=text_memory[vtx_addr];
 end
 reg [7:0] response;
 always @* case(last_bank)
  2'd0:response=q_bg;2'd1:response=q_shared;
  2'd2:response=q_sprite;default:response=q_text;
 endcase
 always @(posedge clk) begin
  if(!reset_n) begin
   hs_inflight<=0;hs_pending<=0;hs_ack_i<=0;hs_rdata_i<=0;
   turn<=0;last_selected<=0;last_valid<=0;last_bank<=0;a_q<=0;b_q<=0;
  end else begin
   hs_ack_i<=0;
   if(!hs_req || !granted)hs_inflight<=0;
   if(hs_accept)hs_inflight<=1;
   hs_pending<=hs_accept;
   if(hs_pending && granted && hs_req)begin hs_rdata_i<=response;hs_ack_i<=1;end
   turn<=!turn;
   last_selected<=selected;last_valid<=selected_req;last_bank<=bank;
   if(last_valid) begin
    if(last_selected)b_q<=response;else a_q<=response;
   end
  end
 end
 // The front-check ASIC examines eight sprite entries together. Eight banks
 // of sixteen words preserve its byte writes and parallel comparison. The
 // same coherent physical sprite view feeds the renderer's synchronous port.
 // Each physical bank has one write port and one asynchronous read port.
 // Separate front/video copies supply the two independent read addresses.
 // The front ASIC does not examine byte1, so that unused copy is omitted.
 wire a_sprite=a_offset>=14'h1000&&a_offset<14'h1080;
 wire a_small=a_offset>=14'h1800&&a_offset<14'h1900;
 wire b_sprite=b_offset>=14'h1000&&b_offset<14'h1080;
 wire b_small=b_offset>=14'h1800&&b_offset<14'h1900;
 wire [3:0] video_index={vspr_addr[6],vspr_addr[5:3]};
 // M10K packing (was 32 separate 16x8 RAMs = one block each): the CPUs never write
 // two sprite bytes in the same clock (see the phase contract below), so one
 // byte-enabled write port is equivalent to the 32 per-byte write enables.
 // video copy: one 128x32 RAM addressed {index,lane}; front copy: one 16x192 RAM
 // (8 lanes x bytes 0,2,3) read for all eight lanes at turbo_select.
 wire a_wr_sp=!granted&&a_write&&(a_sprite||a_small);
 wire b_wr_sp=!granted&&b_write&&(b_sprite||b_small);
 wire sp_we=a_wr_sp||b_wr_sp;
 wire [3:0] sp_widx=b_wr_sp ? {b_small,b_offset[7:5]}:{a_small,a_offset[7:5]};
 wire [2:0] sp_wlane=b_wr_sp ? b_offset[4:2]:a_offset[4:2];
 wire [1:0] sp_wbyte=b_wr_sp ? b_offset[1:0]:a_offset[1:0];
 wire [7:0] sp_wdata=b_wr_sp ? b_data:a_data;
 // Video copy as four byte-wide RAMs (explicit per-byte write enables so Quartus infers M10K; a flat 32-bit array with a
 // sliced write loop became 4096 flops, +1668 ALM in r46). Synchronous read, old-data read-during-write as before.
 (* ramstyle = "M10K" *) reg [7:0] video_mem0[0:127];
 (* ramstyle = "M10K" *) reg [7:0] video_mem1[0:127];
 (* ramstyle = "M10K" *) reg [7:0] video_mem2[0:127];
 (* ramstyle = "M10K" *) reg [7:0] video_mem3[0:127];
 // Front-check copy: 24 separate 16x8 MLABs (lane x bytes 0,2,3) with the async turbo_select read. A flat reg array here was
 // implemented as 3072 flops + a 16:1 mux (+2700 ALMs, r44); MLAB LUT-RAM gives the asynchronous read at ~24 LABs.
 wire [191:0] front_row;
 genvar fl,fbn;
 generate for(fl=0;fl<8;fl=fl+1) begin:front_l
  for(fbn=0;fbn<3;fbn=fbn+1) begin:front_b
   (* ramstyle = "MLAB" *) reg [7:0] front_memory[0:15];
   always @(posedge clk) if(sp_we&&sp_wlane==fl&&sp_wbyte==(fbn==0 ? 2'd0 : fbn==1 ? 2'd2 : 2'd3)) front_memory[sp_widx]<=sp_wdata;
   assign front_row[24*fl+8*fbn+:8]=front_memory[turbo_select];
  end
 end endgenerate
 always @(posedge clk) begin
  if(sp_we&&sp_wbyte==2'd0) video_mem0[{sp_widx,sp_wlane}]<=sp_wdata;
  if(sp_we&&sp_wbyte==2'd1) video_mem1[{sp_widx,sp_wlane}]<=sp_wdata;
  if(sp_we&&sp_wbyte==2'd2) video_mem2[{sp_widx,sp_wlane}]<=sp_wdata;
  if(sp_we&&sp_wbyte==2'd3) video_mem3[{sp_widx,sp_wlane}]<=sp_wdata;
  vspr_data<={video_mem3[{video_index,vspr_addr[2:0]}],video_mem2[{video_index,vspr_addr[2:0]}],video_mem1[{video_index,vspr_addr[2:0]}],video_mem0[{video_index,vspr_addr[2:0]}]};
 end
 genvar bank_lane;
 wire [31:0] turbo_words[0:7];
 generate for(bank_lane=0;bank_lane<8;bank_lane=bank_lane+1) begin:sprite_lane
  assign turbo_words[bank_lane]={front_row[24*bank_lane+16+:8],front_row[24*bank_lane+8+:8],8'd0,front_row[24*bank_lane+:8]};
 end endgenerate
 function automatic outside_probe(input [31:0] sprite,input [8:0] px,py);
  reg [8:0] dx,dy;
  begin
   dx={sprite[31],sprite[23:16]}-px;
   dy={sprite[28],sprite[7:0]}-py;
   outside_probe=!(dx>9'h020&&dx<=9'h1e0&&dy>9'h020&&dy<=9'h1e0);
  end
 endfunction
 genvar lane;
 generate for(lane=0;lane<8;lane=lane+1) begin:front_lane
  assign turbo_data[lane]=outside_probe(turbo_words[lane],turbo_x,turbo_y);
 end endgenerate
 `ifdef VERILATOR
 always @(posedge clk) if(reset_n&&!granted&&a_write&&b_write)
  $fatal(1,"Psycho CPU phase contract violated: simultaneous shared writes");
 `endif
endmodule
