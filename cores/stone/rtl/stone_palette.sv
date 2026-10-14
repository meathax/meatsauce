// SPDX-License-Identifier: GPL-3.0-or-later
// TLC34076 six-bit MAME baseline; physical ADV476 mask mode is selectable.
`default_nettype none
module stone_palette #(parameter ADV476_MASK=0)(
 input wire clk,reset,wr,rd,input wire [3:0] addr,input wire [7:0] din,
 output reg [7:0] dout,input wire vclk,input wire [7:0] pixel,
 output reg [23:0] rgb);
 reg [7:0] regs[0:15];
 reg [1:0] wc,rc;
 reg [7:0] red,green;
 reg [23:0] read_latch;
 wire [7:0] lookup = ADV476_MASK  ?  pixel & regs[2] : pixel;
 reg [23:0] color_q;
 wire [23:0] cpu_color_q,video_color_q;
 reg mask_valid;
 // Port A shares one address for synchronous CPU reads and RGB-triplet writes.
 // regs[3] prefetches between board transactions; gs 7 reads before side effects.
 wire color_we=!reset && wr && addr==1 && wc==2;
 wire [7:0] color_addr=color_we ? regs[0]:regs[3];
 // Both RAM ports use the fabric clock. A dual-clock RAM has undefined
 // read/write collisions. Port B prefetches while pixel is stable between
 // vclk edges, and anticipates the mask which this clk edge will install.
 wire mask_we=!reset && wr && addr==2;
 wire palette_reset=reset || (wr && addr==15);
 wire [7:0] next_mask=palette_reset ? 8'hff:(mask_we ? din:regs[2]);
 wire [7:0] video_addr=ADV476_MASK ? pixel & next_mask:pixel;
 wire [23:0] color_data={red,green,din};
 altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),.intended_device_family("Cyclone V"),
  .width_a(24),.widthad_a(8),.numwords_a(256),.width_b(24),.widthad_b(8),.numwords_b(256),
  .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),.outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
  .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
  .read_during_write_mode_mixed_ports("OLD_DATA"),
  .power_up_uninitialized("FALSE"),.width_byteena_a(1),.width_byteena_b(1),.lpm_type("altsyncram")) colors_ram(
  .clock0(clk),.clock1(1'b1),.clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
  .address_a(color_addr),.data_a(color_data),.wren_a(color_we),.q_a(cpu_color_q),.rden_a(1'b1),.byteena_a(1'b1),
  .address_b(video_addr),.data_b(24'd0),.wren_b(1'b0),.q_b(video_color_q),.rden_b(1'b1),.byteena_b(1'b1),.addressstall_a(1'b0),.addressstall_b(1'b0),.eccstatus());
 // A write on the previous clk edge left port B's OLD_DATA output stale.
 // Forward that completed write. A write coincident with this vclk edge
 // is deliberately not forwarded: the previous implementation reads old data.
 reg color_we_d;
 reg [7:0] color_addr_d;
 reg [23:0] color_data_d;
 always @(posedge clk) begin
   color_we_d<=color_we;color_addr_d<=color_addr;color_data_d<=color_data;
 end
 always @(posedge vclk) begin
   color_q<=color_we_d && color_addr_d==lookup ? color_data_d:video_color_q;
   mask_valid<=ADV476_MASK || ((pixel & regs[2])==pixel);
   rgb<=mask_valid  ?  {color_q[21:16],color_q[21:20],color_q[13:8],color_q[13:12],color_q[5:0],color_q[5:4]} : 24'd0;
 end
 always @* begin
   dout=regs[addr];
   if(addr==1) case(rc)
     0:dout=cpu_color_q[23:16];
     1:dout=read_latch[15:8];
     2:dout=read_latch[7:0];
     default:dout=0;
   endcase
 end
 integer i;
 always @(posedge clk) begin
   if(reset || (wr && addr==15)) begin
     for(i=0;i<16;i=i+1) regs[i]<=0;
     regs[2]<=8'hff; regs[8]<=3; regs[10]<=8'h3f; regs[11]<=8'h2d;
     wc<=0; rc<=0; red<=0; green<=0; read_latch<=0;
   end else begin
     if(wr) begin
       if(addr==1) begin
         case(wc)
           0:begin red<=din; wc<=1; end
           1:begin green<=din; wc<=2; end
           2:begin regs[0]<=regs[0]+1'b1; wc<=0; end
           default:wc<=0;
         endcase
       end else begin regs[addr]<=din; if(addr==0) wc<=0; if(addr==3) rc<=0; end
     end
     if(rd && addr==1) begin
       if(rc==0) read_latch<=cpu_color_q;
       if(rc==2) begin regs[3]<=regs[3]+1'b1; rc<=0; end else rc<=rc+1'b1;
     end
   end
 end
endmodule
`default_nettype wire
