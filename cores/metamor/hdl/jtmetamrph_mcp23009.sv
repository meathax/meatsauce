//
// MCP23009
// (C) 2019 Alexey Melnikov
//
module mcp23009
(
	input            clk,

	output reg [2:0] btn,
	input      [2:0] led,
	output reg       flg_sd_cd,
	output reg       flg_present,
	output reg       flg_mode,

	output	         scl,
	inout 	         sda
);


wire [15:0] init_data[0:11];
assign init_data[0] = 16'h00F8;
assign init_data[1] = 16'h0138;
assign init_data[2] = 16'h0200;
assign init_data[3] = 16'h0300;
assign init_data[4] = 16'h0400;
assign init_data[5] = 16'h0524;
assign init_data[6] = 16'h06FF;
assign init_data[7] = 16'h0700;
assign init_data[8] = 16'h0800;
assign init_data[9] = 16'h0900;
assign init_data[10] = 16'h0A00;
assign init_data[11] = 16'hFFFF;

reg        start = 0;
wire       ready;
wire       error;
reg        rw;
wire [7:0] dout;
reg [15:0] din;

// Ordinary Fast-mode; 2 us low/high allows a 600 ns edge envelope.
i2c #(50_000_000, 250_000) i2c
(
	.CLK(clk),
	.START(start),
	.READ(rw),
	.I2C_ADDR('h20),
	.I2C_WLEN(1),
	.I2C_WDATA1(din[15:8]),
	.I2C_WDATA2(din[7:0]),
	.I2C_RDATA(dout),
	.END(ready),
	.ACK(error),
	.I2C_SCL(scl),
 	.I2C_SDA(sda)
);

always@(posedge clk) begin
	reg  [3:0] idx = 0;
	reg  [1:0] state = 0;
	reg [15:0] timeout = 0;

	if(~&timeout) begin
		timeout <= timeout + 1'd1;
		start   <= 0;
		state   <= 0;
		idx     <= 0;
		btn     <= 0;
		rw      <= 0;
		flg_sd_cd   <= 1;
		flg_present <= 0;
		flg_mode    <= 1;
	end
	else begin
		if(~&init_data[idx]) begin
			case(state)
			0:	begin
					start <= 1;
					state <= 1;
					din   <= init_data[idx];
				end
			1: if(~ready) state <= 2;
			2:	begin
					start <= 0;
					if(ready) begin
						state <= 0;
						if(!error) idx <= idx + 1'd1;
					end
				end
			endcase
		end
		else begin
			case(state)
			0:	begin
					start <= 1;
					state <= 1;
					din   <= {8'h09,5'b00000,led};
				end
			1: if(~ready) state <= 2;
			2:	begin
					start <= 0;
					if(ready) begin
						state <= 0;
						rw <= 0;
						if(!error) begin
							if(rw) begin
								{flg_sd_cd, flg_mode, btn} <= {dout[7:3]};
								flg_present <= 1;
							end
							rw <= ~rw;
						end
					end
				end
			endcase
		end
	end
end


endmodule
