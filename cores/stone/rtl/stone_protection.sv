// SPDX-License-Identifier: GPL-3.0-or-later
// Art & Magic protocol translated from MAME artmagic.cpp, Aaron Giles/Nicola
// Salmoria (BSD-3-Clause). Input MSB first, output LSB first on the same strobe.
// game: 0 Stone Ball, 1 Ultimate Tennis, 2 Cheese Chase (per-game handlers).
`default_nettype none
module stone_protection(input wire clk, reset, strobe, bit_in, input wire [1:0] game, output reg bit_out);
  localparam STONE=2'd0, ULTENNIS=2'd1, CHEESE=2'd2;
  reg [7:0] bytes_in [0:8];
  reg [3:0] byte_count;
  reg [2:0] bit_count;
  reg [7:0] shift_in;
  reg [31:0] shift_out;
  reg [15:0] saved;
  reg [7:0] rnd;
  wire [7:0] incoming = {shift_in[6:0],bit_in};
  wire [7:0] command = byte_count == 0  ?  incoming : bytes_in[0];
  wire [15:0] in_b34 = {bytes_in[4],bytes_in[3]};
  wire [15:0] in_b56 = {bytes_in[6],bytes_in[5]};
  wire [15:0] in_b78 = {incoming,bytes_in[7]};
  // (a-b)*factor>>16 + offset pipeline. The value is first shifted out on the
  // next strobe, a complete 68000 bus cycle (tens of fabric clocks) later, so
  // the registered stages below finish long before it is observed.
  reg [3:0] calc;
  reg [15:0] diff_q, mag_q, offset_q, factor_q;
  reg [31:0] product_q;
  reg [15:0] sq_a, sq_b;
  reg [31:0] sq_q,sq_prod_q;
  reg sq_mode;
  wire [15:0] product_high = diff_q[15]  ?  -product_q[31:16] : product_q[31:16];
  always @(posedge clk) begin
    rnd<=rnd+1'b1;
    if (reset) begin
      bit_out<=0; byte_count<=0; bit_count<=0; shift_in<=0; shift_out<=0; saved<=0; calc<=0; rnd<=0; sq_mode<=0;
    end else begin
      calc<={calc[2:0],1'b0};
      if (calc[0]) begin mag_q<=diff_q[15]  ?  -diff_q : diff_q; sq_q<=sq_a*sq_a; end
      if (calc[1]) begin product_q<=mag_q*factor_q; sq_prod_q<=sq_q*sq_b; end   // sq_q valid after calc[0]
      if (calc[2]) begin
        if (sq_mode) shift_out<=sq_prod_q; // 32-bit truncating a*a*(b/2)
        else shift_out<={16'd0,product_high+offset_q};
      end
      if (strobe) begin
        shift_in<=incoming; bit_out<=shift_out[0]; shift_out<={1'b0,shift_out[31:1]};
        bit_count<=bit_count+1'b1;
        if (bit_count==7) begin
          if (byte_count<9) bytes_in[byte_count]<=incoming;
          byte_count<=byte_count+1'b1;
          case(command)
            // Reset (Ultimate Tennis, Cheese Chase); Stone Ball treats it as unknown.
            0: begin byte_count<=0; shift_out<=(game==STONE) ? 32'd0 : {24'd0,rnd}; end
            1: case(game)
                 STONE: if(byte_count==8) begin       // 01 aaaa bbbb cccc dddd: (a-b)*d>>16 + c
                     diff_q<={bytes_in[2],bytes_in[1]}-in_b34;
                     factor_q<=in_b78; offset_q<=in_b56; sq_mode<=0; calc[0]<=1'b1;
                   end else if(byte_count==10) byte_count<=0;
                 ULTENNIS: if(byte_count==8) begin    // 01 aaaa bbbb cccc dddd: (a-b)*c>>16 + d
                     diff_q<={bytes_in[2],bytes_in[1]}-in_b34;
                     factor_q<=in_b56; offset_q<=in_b78; sq_mode<=0; calc[0]<=1'b1;
                   end else if(byte_count==10) byte_count<=0;
                 default: if(byte_count==4) begin     // 01 aaaa bbbb: (a-b)*0x4000>>16 + 0xa0
                     diff_q<={bytes_in[2],bytes_in[1]}-{incoming,bytes_in[3]};
                     factor_q<=16'h4000; offset_q<=16'h00a0; sq_mode<=0; calc[0]<=1'b1;
                   end else if(byte_count==6) byte_count<=0;
               endcase
            2: case(game)
                 STONE: if(byte_count==2) shift_out<=32'h000000a5;   // 02 aaaa (xx)
                        else if(byte_count==3) byte_count<=0;
                 ULTENNIS: if(byte_count==6) begin                   // 02 aaaa bbbb cccc (xxxxxxxx)
                     sq_a<={bytes_in[2],bytes_in[1]}; sq_b<={1'b0,in_b34[15:1]}; sq_mode<=1; diff_q<=0; calc[0]<=1'b1;
                   end else if(byte_count==10) byte_count<=0;
                 default: begin byte_count<=0; shift_out<=0; end
               endcase
            3: if(byte_count==0) shift_out<={16'd0,saved};
               else if(byte_count==2) byte_count<=0;
            4: if(byte_count==2) begin saved<={incoming,bytes_in[1]}; byte_count<=0; shift_out<=0; end
            default: begin byte_count<=0; shift_out<=0; end
          endcase
        end
      end
    end
  end
endmodule
`default_nettype wire
