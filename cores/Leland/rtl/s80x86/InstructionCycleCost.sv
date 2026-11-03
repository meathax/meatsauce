// SPDX-License-Identifier: GPL-3.0-or-later
// Intel 272430-002 pp27-32 minimum execution cost model for an 80186.
// This is not a BIU/prefetch/wait-state model. A range is not permission to
// choose its lower endpoint as measured silicon timing. External IRQ entry,
// WAIT/TEST and coprocessor ownership require separate controller contracts.
// REP charges setup once and rep_step once per completed iteration. The caller
// supplies the actual encoded non-REP prefix count, evaluated condition, masked
// shift count and masked ENTER nesting level. No production connection yet.
module InstructionCycleCost(
 input wire [7:0] opcode, modrm,
 input wire rep,
 input wire [3:0] prefix_count,
 input wire branch_taken,
 input wire [4:0] shift_count, enter_level,
 output reg valid,
 output wire exact,
 output reg [11:0] minimum, maximum,
 output reg [5:0] rep_step
);
wire memory_operand=modrm[7:6]!=2'b11;
wire [2:0] group=modrm[5:3];
reg [11:0] low_cost, high_cost;
reg is_string;
reg [11:0] prefix_cost;
assign exact=valid && minimum==maximum;
always @* begin
 valid=1;
 low_cost=0; high_cost=0; rep_step=0; is_string=0;
 prefix_cost={7'b0,prefix_count,1'b0};
 case(opcode & 8'hfe)
  8'h6c,8'h6e,8'ha4:begin is_string=1; low_cost=rep?12'd8:12'd14; rep_step=rep?6'd8:6'd0; end
  8'ha6:begin is_string=1; low_cost=rep?12'd5:12'd22; rep_step=rep?6'd22:6'd0; end
  8'haa:begin is_string=1; low_cost=rep?12'd6:12'd10; rep_step=rep?6'd9:6'd0; end
  8'hac:begin is_string=1; low_cost=rep?12'd6:12'd12; rep_step=rep?6'd11:6'd0; end
  8'hae:begin is_string=1; low_cost=rep?12'd5:12'd15; rep_step=rep?6'd15:6'd0; end
  default:;
 endcase
 if(is_string) high_cost=low_cost;
 else if(rep) valid=0;
 else begin
  if(opcode<8'h40 && opcode[2:0]<=3'd5) begin
   if(opcode[2:0]<3'd4) low_cost=memory_operand?12'd10:12'd3;
   else low_cost=opcode[0]?12'd4:12'd3;
  end else if(opcode>=8'h40 && opcode<=8'h4f) low_cost=3;
  else if(opcode>=8'h50 && opcode<=8'h5f) low_cost=10;
  else if(opcode>=8'h70 && opcode<=8'h7f) low_cost=branch_taken?12'd13:12'd4;
  else if(opcode>=8'h90 && opcode<=8'h97) low_cost=3;
  else if(opcode>=8'hb0 && opcode<=8'hbf) low_cost=opcode[3]?12'd4:12'd3;
  else case(opcode)
   8'h80,8'h81,8'h82,8'h83:begin
    if(group==7) low_cost=memory_operand?12'd10:12'd3;
    else low_cost=memory_operand?12'd16:12'd4;
   end
   8'h84,8'h85:low_cost=memory_operand?12'd10:12'd3;
   8'h86,8'h87:low_cost=memory_operand?12'd17:12'd4;
   8'h88,8'h89:low_cost=memory_operand?12'd12:12'd2;
   8'h8a,8'h8b:low_cost=memory_operand?12'd9:12'd2;
   8'h8c,8'h8e:begin
    valid=group<=3 && !(opcode==8'h8e && group==1);
    low_cost=memory_operand ? (opcode==8'h8c ? 12'd11:12'd9) : 12'd2;
   end
   8'h8d,8'hc4,8'hc5:begin
    valid=memory_operand;
    low_cost=opcode==8'h8d ? 12'd6:12'd18;
   end
   8'h8f:begin valid=group==0; low_cost=memory_operand?12'd20:12'd10; end
   8'hc6,8'hc7:begin valid=group==0; low_cost=opcode[0]?12'd13:12'd12; end
   8'hc0,8'hc1,8'hd0,8'hd1,8'hd2,8'hd3:begin
    valid=group!=6;
    if(opcode==8'hd0 || opcode==8'hd1) low_cost=memory_operand?12'd15:12'd2;
    else low_cost=(memory_operand?12'd17:12'd5)+{7'b0,shift_count};
   end
   8'hf6,8'hf7:begin
    case(group)
     0:low_cost=memory_operand?12'd10:12'd4;
     2,3:low_cost=memory_operand?12'd10:12'd3;
     4:low_cost=26;
     5:low_cost=25;
     6:low_cost=29;
     7:low_cost=44;
     default:valid=0;
    endcase
    if(group>=4) begin
     low_cost=low_cost+(opcode[0]?12'd9:12'd0)+(memory_operand?12'd6:12'd0);
     case(group)
      4:high_cost=low_cost+2;
      5:high_cost=low_cost+3;
      6:high_cost=low_cost;
      7:high_cost=low_cost+8;
      default:;
     endcase
    end
   end
   8'hfe,8'hff:begin
    if(group<=1) low_cost=memory_operand?12'd15:12'd3;
    else if(opcode==8'hfe || group==7 || ((group==3 || group==5) && !memory_operand)) valid=0;
    else case(group)
     2:low_cost=memory_operand?12'd19:12'd13;
     3:low_cost=38;
     4:low_cost=memory_operand?12'd17:12'd11;
     5:low_cost=26;
     6:low_cost=memory_operand?12'd16:12'd10;
     default:valid=0;
    endcase
   end
   8'h69,8'h6b:begin low_cost=memory_operand?12'd29:12'd22; high_cost=low_cost+3; end
   8'h62:begin valid=memory_operand; low_cost=33; high_cost=35; end
   8'he0,8'he1,8'he2:low_cost=branch_taken?12'd16:12'd6;
   8'he3:low_cost=branch_taken?12'd15:12'd5;
   8'hce:low_cost=branch_taken?12'd48:12'd4;
   8'hc8:begin
    if(enter_level==0) low_cost=15;
    else if(enter_level==1) low_cost=25;
    else low_cost=22+({7'b0,enter_level}-12'd1)*12'd16;
   end
   8'h06,8'h0e,8'h16,8'h1e,8'h9c:low_cost=9;
   8'h07,8'h17,8'h1f,8'h9d,8'hc9:low_cost=8;
   8'h27,8'h2f,8'h99,8'ha9:low_cost=4;
   8'h37:low_cost=8;
   8'h3f:low_cost=7;
   8'h60:low_cost=36;
   8'h61:low_cost=51;
   8'h68,8'h6a:low_cost=10;
   8'h98,8'h9f,8'hf4,8'hf5,8'hf8,8'hf9,8'hfa,8'hfb,8'hfc,8'hfd:low_cost=2;
   8'h9a:low_cost=23;
   8'h9e,8'ha8:low_cost=3;
   8'ha0,8'ha1,8'hec,8'hed:low_cost=8;
   8'ha2,8'ha3,8'he6,8'he7:low_cost=9;
   8'hc2:low_cost=18;
   8'hc3:low_cost=16;
   8'hca:low_cost=25;
   8'hcb:low_cost=22;
   8'hcc:low_cost=45;
   8'hcd:low_cost=47;
   8'hcf:low_cost=28;
   8'hd4:low_cost=19;
   8'hd5,8'he8:low_cost=15;
   8'hd7:low_cost=11;
   8'he4,8'he5:low_cost=10;
   8'he9,8'hea,8'heb:low_cost=14;
   8'hee,8'hef:low_cost=7;
   default:valid=0;
  endcase
  if(high_cost==0) high_cost=low_cost;
 end
 minimum=valid?low_cost+prefix_cost:12'd0;
 maximum=valid?high_cost+prefix_cost:12'd0;
 if(!valid) rep_step=0;
end
endmodule
