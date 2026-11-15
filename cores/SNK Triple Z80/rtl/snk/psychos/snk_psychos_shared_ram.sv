// Single game clock. Both CPUs share one scheduled RAM port; video uses
// independent bank ports. CPU read responses have at most three master edges
// of latency (request slot, synchronous RAM, tagged response).
module snk_psychos_shared_ram #(parameter HISCORE_ENABLE=0)(
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
 wire hs_address_ok=(hs_addr>=16'hdd05 && hs_addr<=16'hddf9) ||
                    (hs_addr>=16'hfe66 && hs_addr<=16'hfe68);
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
 wire [1:0] bank=offset<14'h0800  ?  2'd0:
                 (offset<14'h1000  ?  2'd1:(offset<14'h2800  ?  2'd2:2'd3));
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
 reg [31:0] turbo_sprites[0:7][0:15];
 wire a_sprite=a_offset>=14'h1000&&a_offset<14'h1080;
 wire a_small=a_offset>=14'h1800&&a_offset<14'h1900;
 wire b_sprite=b_offset>=14'h1000&&b_offset<14'h1080;
 wire b_small=b_offset>=14'h1800&&b_offset<14'h1900;
 always @(posedge clk) begin
  if(!granted&&a_write&&(a_sprite||a_small))
   turbo_sprites[a_offset[4:2]][{a_small,a_offset[7:5]}][8*a_offset[1:0]+:8]<=a_data;
  if(!granted&&b_write&&(b_sprite||b_small))
   turbo_sprites[b_offset[4:2]][{b_small,b_offset[7:5]}][8*b_offset[1:0]+:8]<=b_data;
  vspr_data<=turbo_sprites[vspr_addr[2:0]][{vspr_addr[6],vspr_addr[5:3]}];
 end
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
  assign turbo_data[lane]=outside_probe(turbo_sprites[lane][turbo_select],turbo_x,turbo_y);
 end endgenerate
 `ifdef VERILATOR
 always @(posedge clk) if(reset_n&&!granted&&a_write&&b_write)
  $fatal(1,"Psycho CPU phase contract violated: simultaneous shared writes");
 `endif
endmodule
