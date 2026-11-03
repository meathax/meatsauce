/*  This file is part of JT51.

    JT51 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT51 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT51.  If not, see <http://www.gnu.org/licenses/>.
    
    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-10-2016
    */

// The rst scheme makes this module synthesizable as LUT shift register. This
// saves 18% of logic cells at JT51 top level (3347 vs 2747)
// for the reset value to be applied, the reset must be enabled for as many
// clock cycles as stages are in the shift register
module jt51_sh #(parameter width=5, stages=32, rstval=1'b0 ) (
    input                           rst,
    input                           clk,
    input                           cen,
    input       [width-1:0]         din,
    output      [width-1:0]         drop
);

// Owned DFJail specialization: one31x32 state bank; all other profiles
// retain the original shift implementation and reset/output-mask semantics.
generate if(width==31 && stages==32 && rstval==0)begin:g_ram_shift
 reg [4:0] write_ptr=0;
 wire [4:0] read_ptr=write_ptr+5'd1;
 wire [30:0] ram_q;
 always @(posedge clk)if(cen)write_ptr<=read_ptr;
 altsyncram #(
  .intended_device_family("Cyclone V"),.ram_block_type("M10K"),
  .operation_mode("DUAL_PORT"),.width_a(31),.width_b(31),
  .widthad_a(5),.widthad_b(5),.numwords_a(32),.numwords_b(32),
  .width_byteena_a(1),.address_reg_b("CLOCK0"),
  .outdata_reg_b("UNREGISTERED"),.outdata_aclr_b("NONE"),
  .clock_enable_input_a("NORMAL"),.clock_enable_input_b("NORMAL"),
  .clock_enable_output_b("BYPASS"),.power_up_uninitialized("TRUE"),
  .read_during_write_mode_mixed_ports("DONT_CARE")
 ) history(.clock0(clk),.clock1(1'b1),.clocken0(cen),.clocken1(1'b1),
  .clocken2(1'b1),.clocken3(1'b1),.addressstall_a(1'b0),.addressstall_b(1'b0),
  .aclr0(1'b0),.aclr1(1'b0),.address_a(write_ptr),.data_a(din),
  .wren_a(1'b1),.byteena_a(1'b1),.address_b(read_ptr),.rden_b(1'b1),
  .wren_b(1'b0),.data_b(31'd0),.byteena_b(1'b1),.rden_a(1'b1),.q_b(ram_q),.q_a(),.eccstatus());
 assign drop=rst?{width{rstval[0]}}:ram_q;
end else begin:g_original
reg [stages-1:0] bits[width-1:0];

genvar i;
    for (i=0; i < width; i=i+1) begin: bit_shifter
        always @(posedge clk) if(cen) begin
            bits[i] <= {bits[i][stages-2:0], din[i]};
        end
        assign drop[i] = rst ? rstval[0] : bits[i][stages-1];
    end

end endgenerate
endmodule
