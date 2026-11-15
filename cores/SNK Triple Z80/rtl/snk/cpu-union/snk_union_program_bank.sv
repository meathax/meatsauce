// SPDX-License-Identifier: GPL-3.0-or-later
// One logical program bank; three disjoint memories, never replicated per profile.
// Native slots A=0, B=0x10000, S=0x20000. CPU fetch has no arbiter/WAIT.
// Profile changes and loading require all three CPUs held in reset by the owner.
// Loader must write the complete mapped image, including MAME zero-filled holes.
module snk_union_program_bank(
 input wire clk,input wire [7:0] profile,input wire load_wr,
 input wire [24:0] load_addr,input wire [7:0] load_data,
 input wire [47:0] cpu_addr,output reg [23:0] rom_data
);
 (* ramstyle="M10K" *) reg [7:0] rom_a[0:49151];
 (* ramstyle="M10K" *) reg [7:0] rom_b[0:49151];
 (* ramstyle="M10K" *) reg [7:0] rom_s[0:49151];
 function automatic [16:0] limit(input [7:0] id,input integer lane);
 begin case(id)
   8'd13:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd11:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd12:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd19:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd16:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd5:case(lane) 0:limit=17'd32768;1:limit=17'd40960;2:limit=17'd16384;default:limit=0;endcase
   8'd2:case(lane) 0:limit=17'd32768;1:limit=17'd40960;2:limit=17'd16384;default:limit=0;endcase
   8'd0:case(lane) 0:limit=17'd24576;1:limit=17'd24576;2:limit=17'd16384;default:limit=0;endcase
   8'd1:case(lane) 0:limit=17'd32768;1:limit=17'd40960;2:limit=17'd16384;default:limit=0;endcase
   8'd3:case(lane) 0:limit=17'd40960;1:limit=17'd32768;2:limit=17'd16384;default:limit=0;endcase
   8'd4:case(lane) 0:limit=17'd40960;1:limit=17'd32768;2:limit=17'd16384;default:limit=0;endcase
   8'd14:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd18:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd15:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd6,8'd8,8'd9,8'd10:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   8'd7:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd32768;default:limit=0;endcase
   8'd17:case(lane) 0:limit=17'd49152;1:limit=17'd49152;2:limit=17'd49152;default:limit=0;endcase
   default:limit=0;
 endcase end endfunction
 wire [16:0] al=limit(profile,0),bl=limit(profile,1),sl=limit(profile,2);
 always @(posedge clk)begin
  rom_data[7:0] <= {1'b0,cpu_addr[15:0]}<al ? rom_a[cpu_addr[15:0]] : 8'hff;
  rom_data[15:8] <= {1'b0,cpu_addr[31:16]}<bl ? rom_b[cpu_addr[31:16]] : 8'hff;
  rom_data[23:16] <= {1'b0,cpu_addr[47:32]}<sl ? rom_s[cpu_addr[47:32]] : 8'hff;
  if(load_wr)case(load_addr[24:16])
   0:if({1'b0,load_addr[15:0]}<al)rom_a[load_addr[15:0]]<=load_data;
   1:if({1'b0,load_addr[15:0]}<bl)rom_b[load_addr[15:0]]<=load_data;
   2:if({1'b0,load_addr[15:0]}<sl)rom_s[load_addr[15:0]]<=load_data;
  endcase
 end
endmodule
