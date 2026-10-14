// SPDX-License-Identifier: GPL-3.0-or-later
// Scanline composition: live VRAM fetch, BG0, BG1, eight sprites/bank.
// One graphics row port and one VRAM port; no frame snapshot or sprite ROM copies.
module drmicro_video #(parameter integer NMI_LINE=239, NMI_X=316, FRAME_ORIGIN=240)(
 input logic clk,reset,ce,flip,
 output logic [11:0] va,
 input logic [7:0] vd,
 output logic [12:0] ga,
 input logic [15:0] g0,
 input logic [23:0] g1,
 output logic [8:0] pen,
 input logic [7:0] color,
 output logic [7:0] red,green,blue,
 output logic hs,vs,hblank,vblank,pixel_ce,frame_event,
 output logic [8:0] debug_x,
 output logic [7:0] debug_y,
 output logic deadline_error
);
 logic [8:0] x;
 logic [7:0] y;
 logic [8:0] lines[0:511];
 logic [1:0] valid;
 logic [7:0] tag[0:1];
 logic [8:0] line_q;
 logic [3:0] ce_pipe;
 logic [3:0] hs_pipe,vs_pipe,hb_pipe,vb_pipe;
 logic [8:0] xp[0:3];logic [7:0] yp[0:3];
 logic [7:0] target,code,attr,sy,sx,schr,sattr;
 logic [4:0] tile;
 logic bank,render_flip;
 logic [2:0] pix;
 logic [3:0] sp;
 logic half;
 logic [3:0] row;
 logic [23:0] rowbits;
 logic [8:0] destination;
 logic [2:0] raw;
 logic [8:0] value;
 logic [3:0] sample_x;
 logic [7:0] sprite_y,sprite_x;
 typedef enum logic [4:0] {IDLE,T_CODE,T_CODE_WAIT,T_ATTR,T_ATTR_WAIT,T_GFX,T_GFX_WAIT,T_DRAW,
 S_Y,S_Y_WAIT,S_C,S_C_WAIT,S_A,S_A_WAIT,S_X,S_X_WAIT,S_TEST,S_GFX,S_GFX_WAIT,S_DRAW,S_NEXT,DONE} state_t;
 state_t state;
 wire line_start=ce&&x==0;
 wire [7:0] next_y=y+8'd1;
 wire [7:0] tile_y=render_flip?~target:target;
 wire [4:0] tile_col=render_flip?~tile:tile;
 wire [2:0] tile_row=tile_y[2:0]^{3{attr[5]}};
 wire [7:0] tile_x={tile,3'b0}+{5'd0,pix};
 wire [2:0] tile_bit=pix^{3{attr[4]^render_flip}};
 wire [3:0] sprite_bit={half,pix}^{4{schr[0]^render_flip}};
 always_comb begin
  sprite_y=render_flip?sy:(8'd240-sy);
  sprite_x=render_flip?(8'd240-sx):sx;
  va=0;ga=0;
  case(state)
   T_CODE,T_CODE_WAIT:va={~bank,1'b0,tile_y[7:3],tile_col};
   T_ATTR,T_ATTR_WAIT:va={~bank,1'b1,tile_y[7:3],tile_col};
   S_Y,S_Y_WAIT:va={~bank,6'b0,sp[2:0],2'b00};
   S_C,S_C_WAIT:va={~bank,6'b0,sp[2:0],2'b01};
   S_A,S_A_WAIT:va={~bank,6'b0,sp[2:0],2'b10};
   S_X,S_X_WAIT:va={~bank,6'b0,sp[2:0],2'b11};
   default:;
  endcase
  if(state==T_GFX||state==T_GFX_WAIT)ga={attr[7:6],code,tile_row};
  if(state==S_GFX||state==S_GFX_WAIT)ga={sattr[7:6],schr[7:2],row[3],half^(schr[0]^render_flip),row[2:0]};
  sample_x=state==T_DRAW?{1'b0,tile_bit}:sprite_bit;
  if(bank)raw={rowbits[{2'b10,sample_x[2:0]}],rowbits[{2'b01,sample_x[2:0]}],rowbits[{2'b00,sample_x[2:0]}]};
  else raw={1'b0,rowbits[{2'b00,sample_x[2:0]}],rowbits[{2'b01,sample_x[2:0]}]};
  if(state==T_DRAW)begin
   destination={target[0],tile_x};
   value=bank?{1'b1,1'b0,attr[3:0],raw}:{3'b0,attr[3:0],raw[1:0]};
  end else begin
   destination={target[0],8'(sprite_x+{half,pix})};
   value=bank?{1'b1,1'b0,sattr[3:0],raw}:{3'b0,sattr[3:0],raw[1:0]};
  end
 end
 assign pen=line_q;
 assign debug_x=xp[3];assign debug_y=yp[3];
 assign pixel_ce=ce_pipe[3];assign hs=hs_pipe[3];assign vs=vs_pipe[3];
 assign hblank=hb_pipe[3];assign vblank=vb_pipe[3];
 always_ff @(posedge clk) begin
  if(reset)begin
   x<=0;y<=8'(FRAME_ORIGIN);state<=IDLE;valid<=0;deadline_error<=0;frame_event<=0;
   ce_pipe<=0;hs_pipe<=0;vs_pipe<=0;hb_pipe<=15;vb_pipe<=15;
   red<=0;green<=0;blue<=0;line_q<=0;
   target<=0;render_flip<=0;bank<=0;tile<=0;pix<=0;sp<=0;half<=0;row<=0;
   code<=0;attr<=0;sy<=0;sx<=0;schr<=0;sattr<=0;rowbits<=0;
   for(integer i=0;i<4;i=i+1)begin xp[i]<=0;yp[i]<=0;end
  end else begin
   frame_event<=ce&&x==9'(NMI_X)&&y==8'(NMI_LINE);
   if(ce)begin
    if(x==319)begin x<=0;y<=y+8'd1;end else x<=x+9'd1;
   end
   line_q<=(valid[y[0]]&&tag[y[0]]==y)?lines[{y[0],x[7:0]}]:9'd0;
   ce_pipe<={ce_pipe[2:0],ce};hs_pipe<={hs_pipe[2:0],x>=272&&x<304};
   vs_pipe<={vs_pipe[2:0],y>=244&&y<248};
   hb_pipe<={hb_pipe[2:0],x>=256};vb_pipe<={vb_pipe[2:0],y<16||y>=240};
   xp[0]<=x;yp[0]<=y;
   for(integer i=1;i<4;i=i+1)begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];end
   red<=8'((color[0]?33:0)+(color[1]?71:0)+(color[2]?151:0));
   green<=8'((color[3]?33:0)+(color[4]?71:0)+(color[5]?151:0));
   blue<=8'((color[6]?82:0)+(color[7]?173:0));
   if(line_start)begin
    if(state!=IDLE)deadline_error<=1;
    target<=next_y;render_flip<=flip;tile<=0;bank<=0;pix<=0;
    valid[next_y[0]]<=0;state<=T_CODE;
   end else case(state)
    IDLE:;
    T_CODE:state<=T_CODE_WAIT;
    T_CODE_WAIT:begin code<=vd;state<=T_ATTR;end
    T_ATTR:state<=T_ATTR_WAIT;
    T_ATTR_WAIT:begin attr<=vd;state<=T_GFX;end
    T_GFX:state<=T_GFX_WAIT;
    T_GFX_WAIT:begin rowbits<=bank?g1:{8'd0,g0};pix<=0;state<=T_DRAW;end
    T_DRAW:begin
     if(!bank||raw!=0)lines[destination]<=value;
     if(pix==7)begin
      pix<=0;
      if(tile==31)begin
       tile<=0;
       if(bank)begin bank<=0;sp<=0;state<=S_Y;end
       else begin bank<=1;state<=T_CODE;end
      end else begin tile<=tile+5'd1;state<=T_CODE;end
     end else pix<=pix+3'd1;
    end
    S_Y:state<=S_Y_WAIT;
    S_Y_WAIT:begin sy<=vd;state<=S_C;end
    S_C:state<=S_C_WAIT;
    S_C_WAIT:begin schr<=vd;state<=S_A;end
    S_A:state<=S_A_WAIT;
    S_A_WAIT:begin sattr<=vd;state<=S_X;end
    S_X:state<=S_X_WAIT;
    S_X_WAIT:begin sx<=vd;state<=S_TEST;end
    S_TEST:begin
     // Vertical clipping is NOT modulo-256 wrapping in MAME.
     if({1'b0,target}>={1'b0,sprite_y}&&{1'b0,target}<{1'b0,sprite_y}+9'd16)begin
      row<=4'(target-sprite_y)^{4{schr[1]^render_flip}};half<=0;state<=S_GFX;
     end else state<=S_NEXT;
    end
    S_GFX:state<=S_GFX_WAIT;
    S_GFX_WAIT:begin rowbits<=bank?g1:{8'd0,g0};pix<=0;state<=S_DRAW;end
    S_DRAW:begin
     // Transparent pixels never claim ownership; ascending records overwrite.
     if(raw!=0)lines[destination]<=value;
     if(pix==7)begin
      if(half)state<=S_NEXT;else begin half<=1;state<=S_GFX;end
     end else pix<=pix+3'd1;
    end
    S_NEXT:begin
     if(sp[2:0]==7)begin
      if(bank)state<=DONE;else begin bank<=1;sp<=0;state<=S_Y;end
     end else begin sp<=sp+4'd1;state<=S_Y;end
    end
    DONE:begin valid[target[0]]<=1;tag[target[0]]<=target;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
