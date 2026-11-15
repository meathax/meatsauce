// Late-board enables from the 96MHz master (clk).
// CPU/audio 4MHz = clk/24 (uniform spacing); cen_n is half a period from cen_p.
// Pixel 8MHz = clk/12 (uniform spacing, exact 16MHz-crystal board pixel).
// 512x256 is 61.035Hz for the 16MHz family; Chopper I uses 512x255 = 61.275Hz,
// matching PCB measurements 61.01Hz (Gwar) and 61.326Hz (Chopper I) within 0.1%.
module snk_psychos_cen(input wire clk,reset,output reg cen_p,cen_n,pxl_cen);
 reg [4:0] cpu_div=0;
 reg [3:0] pix=0;
 always @(posedge clk) begin
  if(reset) begin
   cpu_div<=0; pix<=0; cen_p<=0; cen_n<=0; pxl_cen<=0;
  end else begin
   cen_p<=cpu_div==5'd23;
   cen_n<=cpu_div==5'd11;
   cpu_div<=cpu_div==5'd23 ? 5'd0 : cpu_div+1'b1;
   pix<=pix==4'd11 ? 4'd0 : pix+1'b1;
   pxl_cen<=pix==4'd11;
  end
 end
endmodule

// Guerrilla War game-CPU (A/B) enables: 8MHz (mode 0), 6MHz (1) or the PCB 4MHz (2,3)
// from one clk/48 grid. Mode 2 reproduces snk_psychos_cen's cen_p/cen_n phases exactly
// (both counters leave reset together). Every mode issues cen_p at div 47, so a mode
// change applied there keeps p/n alternation and the >=12-clock CEN_p spacing that the
// T80 multicycle constraint relies on. Sound CPU/OPL/pixel enables are unaffected.
module snk_late_boost_cen(input wire clk,reset,input wire [1:0] mode,output reg cen_p,cen_n);
 reg [5:0] div=0;
 reg [1:0] mode_q=2'd2;
 always @(posedge clk) begin
  if(reset) begin
   div<=0; mode_q<=mode; cen_p<=0; cen_n<=0;
  end else begin
   div<=div==6'd47 ? 6'd0 : div+1'b1;
   if(div==6'd47) mode_q<=mode;
   case(mode_q)
    2'd0: begin
     cen_p<=div==6'd11||div==6'd23||div==6'd35||div==6'd47;
     cen_n<=div==6'd5||div==6'd17||div==6'd29||div==6'd41;
    end
    2'd1: begin
     cen_p<=div==6'd15||div==6'd31||div==6'd47;
     cen_n<=div==6'd7||div==6'd23||div==6'd39;
    end
    default: begin
     cen_p<=div==6'd23||div==6'd47;
     cen_n<=div==6'd11||div==6'd35;
    end
   endcase
  end
 end
endmodule
