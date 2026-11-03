// SPDX-License-Identifier: GPL-3.0-or-later
// Fair two-client Avalon command mux with retained read-response ownership.
// Both clients hold complete tuples while busy. Reset is the physical DDR
// transport reset, never the game reset (accepted replies survive game reset).
module leland_ddr_client_mux (
 input clk, input reset,
 input [28:0] a_addr, input [63:0] a_din, input a_rd, input a_we,
 output a_busy, output [63:0] a_dout, output a_ready,
 input [28:0] b_addr, input [63:0] b_din, input b_rd, input b_we,
 output b_busy, output [63:0] b_dout, output b_ready,
 output [28:0] addr, output [63:0] din, output rd, output we,
 input busy, input [63:0] dout, input ready,
 output reg fault = 1'b0
);
 reg last_b=0, locked=0, lock_b=0;
 reg owner [0:511];
 reg [8:0] wp=0, rp=0;
 reg [9:0] count=0;
 wire ap=a_rd||a_we, bp=b_rd||b_we;
 wire pick_b=locked ? lock_b : (bp && (!ap || !last_b));
 wire pending=pick_b ? bp : ap;
 wire want_read=pick_b ? b_rd : a_rd;
 wire pop=ready && count!=0;
 // Capacity must not depend on the returned ready signal. Pop-through at
 // full creates a ready -> request -> immediate-response -> ready loop when
 // composed with the upstream owner. One full-FIFO bubble breaks that loop.
 wire space=count<512;
 assign addr=pick_b ? b_addr : a_addr;
 assign din=pick_b ? b_din : a_din;
 assign rd=pending && want_read && space;
 assign we=pending && !want_read && (pick_b ? b_we : a_we);
 wire accept=pending && (!want_read || space) && !busy;
 wire accept_read=accept && want_read;
 wire immediate=ready && count==0 && accept_read;
 wire push=accept_read && !immediate;
 wire response_b=count!=0 ? owner[rp] : pick_b;
 assign a_busy=busy || pick_b || (a_rd && !space);
 assign b_busy=busy || !pick_b || (b_rd && !space);
 assign a_dout=dout;
 assign b_dout=dout;
 assign a_ready=ready && (count!=0 || accept_read) && !response_b;
 assign b_ready=ready && (count!=0 || accept_read) && response_b;
 always @(posedge clk) begin
  if (reset) begin
   last_b<=0; locked<=0; lock_b<=0; wp<=0; rp<=0; count<=0; fault<=0;
  end else begin
   if (ready && count==0 && !accept_read) fault<=1;
   if (pending && !accept) begin locked<=1; lock_b<=pick_b; end
   if (accept) begin locked<=0; last_b<=pick_b; end
   if (push) begin owner[wp]<=pick_b; wp<=wp+1'b1; end
   if (pop) rp<=rp+1'b1;
   case ({push,pop})
    2'b10: count<=count+1'b1;
    2'b01: count<=count-1'b1;
    default: ;
   endcase
  end
 end
endmodule
