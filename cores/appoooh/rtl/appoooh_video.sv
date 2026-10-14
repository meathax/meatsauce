// SPDX-License-Identifier: GPL-3.0-or-later
// Appoooh two-playfield, two-sprite-set scanline renderer.
// Video RAM and graphics PROM reads are synchronous and share one live port.
module appoooh_video #(
 parameter integer NMI_LINE=239, NMI_X=316, FRAME_ORIGIN=240
)(
 input logic clk,reset,ce,flip,robowres_mode,
 input logic [1:0] prio,
 output logic [11:0] va,
 input logic [7:0] vd,
 output logic [14:0] ga,
 input logic [23:0] gfx0,gfx1,
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
 logic [3:0] ce_pipe,hs_pipe,vs_pipe,hb_pipe,vb_pipe;
 logic [8:0] xp[0:3];
 logic [7:0] yp[0:3];
 logic [7:0] target,code,attr,sy,sx,schr,sattr;
 logic [4:0] tile;
 logic layer,sprite_set,sprite_pass,render_flip;
 logic [1:0] render_priority;
 logic [2:0] pix;
 logic [3:0] sp,row;
 logic half;
 logic [23:0] rowbits;
 logic [8:0] destination;
 logic [2:0] raw,bit_index;
 logic [8:0] value;
 typedef enum logic [4:0] {
  IDLE,T_CODE,T_CODE_WAIT,T_ATTR,T_ATTR_WAIT,T_GFX,T_GFX_WAIT,T_DRAW,
  S_Y,S_Y_WAIT,S_C,S_C_WAIT,S_A,S_A_WAIT,S_X,S_X_WAIT,S_TEST,
  S_GFX,S_GFX_WAIT,S_DRAW,S_NEXT,DONE
 } state_t;
 state_t state;
 wire line_start=ce&&x==0;
 wire [7:0] next_y=y+8'd1;
wire [7:0] tile_y=render_flip?(8'd247-target):(target-8'd8);
 wire [4:0] tile_col=render_flip?~tile:tile;
 wire [9:0] tile_index={tile_y[7:3],tile_col};
 wire [10:0] tile_code={attr[7:5],code};
wire [9:0] sprite_code={robowres_mode,sattr[7:5],schr[7:2]};
wire sprite_flip_x=schr[0]^render_flip;
wire tile_flip_x=attr[4]^render_flip;
wire [7:0] sprite_y=render_flip?(sy-8'd1):(8'd240-sy);
wire [7:0] sprite_y_offset=target-sprite_y;
wire [3:0] sprite_row=render_flip?(4'd15-sprite_y_offset[3:0]):sprite_y_offset[3:0];
wire signed [9:0] sprite_x_unflipped=(sx>=8'd248)?$signed({2'b11,sx}):$signed({2'b00,sx});
wire signed [9:0] sprite_x=render_flip?(10'sd239-sprite_x_unflipped):sprite_x_unflipped;
wire signed [9:0] sprite_pixel_x=sprite_x+$signed({6'd0,half,pix});
wire sprite_pixel_visible=sprite_pixel_x>=0&&sprite_pixel_x<256;

 always_comb begin
  va=12'd0;
  ga=15'd0;
  bit_index=~pix;
  if(state==T_CODE||state==T_CODE_WAIT)
   va=layer?12'h820+{2'b0,tile_index}:12'h020+{2'b0,tile_index};
  if(state==T_ATTR||state==T_ATTR_WAIT)
   va=layer?12'hc20+{2'b0,tile_index}:12'h420+{2'b0,tile_index};
  if(state==S_Y||state==S_Y_WAIT)
   va=(sprite_set?12'h800:12'h000)+{7'd0,sp[2:0],2'b00};
  if(state==S_C||state==S_C_WAIT)
   va=(sprite_set?12'h800:12'h000)+{7'd0,sp[2:0],2'b01};
  if(state==S_A||state==S_A_WAIT)
   va=(sprite_set?12'h800:12'h000)+{7'd0,sp[2:0],2'b10};
  if(state==S_X||state==S_X_WAIT)
   va=(sprite_set?12'h800:12'h000)+{7'd0,sp[2:0],2'b11};
  if(state==T_GFX||state==T_GFX_WAIT)ga={1'b0,tile_code,tile_y[2:0]};
  if(state==S_GFX||state==S_GFX_WAIT)
   ga={sprite_code,sprite_row[3],(half^sprite_flip_x),sprite_row[2:0]};
  if(state==T_DRAW)bit_index=pix^{3{tile_flip_x}};
  else bit_index=pix^{3{sprite_flip_x}};
  raw={rowbits[{2'b10,bit_index}],rowbits[{2'b01,bit_index}],rowbits[{2'b00,bit_index}]};
  if(state==T_DRAW)begin
   destination={target[0],tile,pix};
   value={layer,1'b0,attr[3:0],raw};
  end else begin
   destination={target[0],sprite_pixel_x[7:0]};
   value={sprite_set,1'b0,sattr[3:0],raw};
  end
 end

 assign pen=line_q;
 assign debug_x=xp[3];
 assign debug_y=yp[3];
 assign pixel_ce=ce_pipe[3];
 assign hs=hs_pipe[3];
 assign vs=vs_pipe[3];
 assign hblank=hb_pipe[3];
 assign vblank=vb_pipe[3];

 always_ff @(posedge clk)begin
  if(reset)begin
   x<=0;y<=8'(FRAME_ORIGIN);state<=IDLE;valid<=0;deadline_error<=0;frame_event<=0;
   ce_pipe<=0;hs_pipe<=0;vs_pipe<=0;hb_pipe<=15;vb_pipe<=15;
   red<=0;green<=0;blue<=0;line_q<=0;
   target<=0;layer<=1;sprite_set<=1;sprite_pass<=0;render_flip<=0;render_priority<=0;
   tile<=0;pix<=0;sp<=0;half<=0;row<=0;
   code<=0;attr<=0;sy<=0;sx<=0;schr<=0;sattr<=0;rowbits<=0;
   for(integer i=0;i<4;i=i+1)begin xp[i]<=0;yp[i]<=0;end
  end else begin
   frame_event<=ce&&x==9'(NMI_X)&&y==8'(NMI_LINE);
   if(ce)begin
    if(x==319)begin x<=0;y<=y+8'd1;end else x<=x+9'd1;
   end
   line_q<=(valid[y[0]]&&tag[y[0]]==y)?lines[{y[0],x[7:0]}]:9'd0;
   ce_pipe<={ce_pipe[2:0],ce};
   hs_pipe<={hs_pipe[2:0],x>=272&&x<304};
   vs_pipe<={vs_pipe[2:0],y>=244&&y<248};
   hb_pipe<={hb_pipe[2:0],x>=256};
   vb_pipe<={vb_pipe[2:0],y<16||y>=240};
   xp[0]<=x;yp[0]<=y;
   for(integer i=1;i<4;i=i+1)begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];end
   red<=8'((color[0]?33:0)+(color[1]?71:0)+(color[2]?151:0));
   green<=8'((color[3]?33:0)+(color[4]?71:0)+(color[5]?151:0));
   blue<=8'((color[6]?82:0)+(color[7]?173:0));

   if(line_start)begin
    if(state!=IDLE)deadline_error<=1;
   target<=next_y;render_flip<=flip;render_priority<=prio;
    tile<=0;pix<=0;layer<=1;sprite_set<=1;sprite_pass<=0;
    valid[next_y[0]]<=0;state<=T_CODE;
   end else case(state)
    IDLE:;
    T_CODE:state<=T_CODE_WAIT;
    T_CODE_WAIT:begin code<=vd;state<=T_ATTR;end
    T_ATTR:state<=T_ATTR_WAIT;
    T_ATTR_WAIT:begin attr<=vd;state<=T_GFX;end
    T_GFX:state<=T_GFX_WAIT;
    T_GFX_WAIT:begin rowbits<=layer?gfx1:gfx0;pix<=0;state<=T_DRAW;end
    T_DRAW:begin
     if(layer||raw!=0)lines[destination]<=value;
     if(pix==7)begin
      pix<=0;
      if(tile==31)begin
       tile<=0;
       if(layer)begin
        if(render_priority==0)begin layer<=0;state<=T_CODE;end
        else begin sprite_set<=render_priority==1?0:1;sprite_pass<=0;sp<=7;state<=S_Y;end
       end else if(render_priority==0)begin sprite_set<=1;sprite_pass<=0;sp<=7;state<=S_Y;end
       else state<=DONE;
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
      if(sprite_y_offset[7:4]==0)begin
      row<=sprite_row;half<=0;state<=S_GFX;
      end else if(sp[2:0]==0)begin
       if(!sprite_pass)begin sprite_pass<=1;sprite_set<=~sprite_set;sp<=7;state<=S_Y;end
       else if(render_priority==0)state<=DONE;
       else begin layer<=0;tile<=0;state<=T_CODE;end
      end
     else begin sp<=sp-4'd1;state<=S_Y;end
    end
    S_GFX:state<=S_GFX_WAIT;
    S_GFX_WAIT:begin rowbits<=sprite_set?gfx1:gfx0;pix<=0;state<=S_DRAW;end
    S_DRAW:begin
     if(sprite_pixel_visible&&raw!=0)lines[destination]<=value;
     if(pix==7)begin
      pix<=0;
      if(!half)begin half<=1;state<=S_GFX;end else state<=S_NEXT;
     end else pix<=pix+3'd1;
    end
    S_NEXT:begin
     if(sp[2:0]==0)begin
      if(!sprite_pass)begin sprite_pass<=1;sprite_set<=~sprite_set;sp<=7;state<=S_Y;end
      else if(render_priority==0)state<=DONE;
      else begin layer<=0;tile<=0;state<=T_CODE;end
     end
     else begin sp<=sp-4'd1;state<=S_Y;end
    end
    DONE:begin valid[target[0]]<=1;tag[target[0]]<=target;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
