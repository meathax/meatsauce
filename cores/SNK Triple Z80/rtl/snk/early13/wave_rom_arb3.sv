// 3-client toggle req/ack arbiter onto one 32-bit word port (tile ROM port: sel 0=tx 1=fg 2=bg).
module wave_rom_arb3(
  input clk, input reset,
  input [2:0] c_req, output reg [2:0] c_ack = 3'b000, input [10:0] a0, a1, a2, output reg [31:0] c_data,
  output reg p_req = 1'b0, input p_ack, output reg [1:0] p_sel, output reg [10:0] p_addr, input [31:0] p_data);
  reg busy; reg [1:0] who;
  wire [2:0] pend = c_req ^ c_ack;
  always @(posedge clk) begin
    if (reset) begin busy <= 0; p_req <= p_ack; c_ack <= c_req; end
    else if (!busy) begin
      if (pend[0]) begin who <= 0; p_sel <= 0; p_addr <= a0; p_req <= ~p_req; busy <= 1; end
      else if (pend[1]) begin who <= 1; p_sel <= 1; p_addr <= a1; p_req <= ~p_req; busy <= 1; end
      else if (pend[2]) begin who <= 2; p_sel <= 2; p_addr <= a2; p_req <= ~p_req; busy <= 1; end
    end else if (p_ack == p_req) begin
      c_data <= p_data; c_ack[who] <= c_req[who]; busy <= 0;
    end
  end
endmodule
