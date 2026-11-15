//============================================================================
//
//  ALSA sound support for MiSTer
//  (c)2019,2020 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module seicro_alsa
#(
	parameter CLK_RATE = 24576000
)
(
	input             reset,
	input             clk,
	
	output reg [31:3] ram_address,
	input      [63:0] ram_data,
	output reg        ram_req = 0,
	input             ram_ready,

	input             spi_ss,
	input             spi_sck,
	input             spi_mosi,
	output            spi_miso,

	output reg [15:0] pcm_l,
	output reg [15:0] pcm_r
);

// Remember reset assertion with a stopped audio clock, and release only after
// two local edges. Receive configuration/banks remain retained, as before.
wire playback_reset;
seicro_alsa_reset_release u_playback_reset(.clk(clk),.async_reset(reset),.local_reset(playback_reset));

reg [31:0] spi_out = 0;
reg  [2:0] hurryup = 0;
reg [18:3] buf_rptr = 0;
reg ce_sample;
reg [63:0] readdata;
reg [18:3] len = 0;
reg [1:0] ready = 0;
reg got_first = 0;
reg [7:0] ce_cnt = 0;
reg [1:0] state = 0;
reg [31:0] acc = 0;
wire [6:0] spicnt;
wire [60:0] descriptor;
seicro_alsa_rx u_rx(.spi_ss(spi_ss),.spi_sck(spi_sck),.spi_mosi(spi_mosi),.clk(clk),.spicnt(spicnt),.descriptor(descriptor));

assign spi_miso = spi_out[{spicnt[4:3],~spicnt[2:0]}];


always @(posedge clk) if(spi_ss) spi_out <= {buf_rptr, hurryup, 8'h00};


wire [31:3] buf_addr=descriptor[28:0];
wire [18:3] buf_len=descriptor[44:29];
wire [18:3] buf_wptr=descriptor[60:45];




always @(posedge clk) begin : playback

	if(playback_reset) begin
		ready     <= 0;
		ce_cnt    <= 0;
        // Playback reset flushes PCM, not an accepted DDR transaction. Keep
        // request/address ownership until its one-beat response has drained.
        // This also handles a response delivered while reset remains asserted.
        if(state==1 || state==2) state <= ram_ready ? 0 : 2;
        else state <= 0;
		got_first <= 0;
		len       <= 0;
	end
	else begin

		//ramp up
		if(len[18:14] && (hurryup < 1)) hurryup <= 1;
		if(len[18:16] && (hurryup < 2)) hurryup <= 2;
		if(len[18:17] && (hurryup < 4)) hurryup <= 4;

		//ramp down
		if(!len[18:15] && (hurryup > 2)) hurryup <= 2;
		if(!len[18:13] && (hurryup > 1)) hurryup <= 1;
		if(!len[18:10]) hurryup <= 0;

		if(ce_sample && ~&ce_cnt) ce_cnt <= ce_cnt + 1'd1;

		case(state)
		0: if(!ce_sample) begin
				if(ready) begin
					if(ce_cnt) begin
						{readdata[31:0],pcm_r,pcm_l} <= readdata;
						ready <= ready - 1'd1;
						ce_cnt <= ce_cnt - 1'd1;
					end
				end
				else if(buf_rptr != buf_wptr) begin
					if(~got_first) begin
						buf_rptr <= buf_wptr;
						got_first <= 1;
					end
					else begin
						ram_address <= buf_addr + buf_rptr;
						ram_req <= ~ram_req;
						buf_rptr <= buf_rptr + 1'd1;
						len <= (buf_wptr < buf_rptr) ? (buf_len + buf_wptr - buf_rptr) : (buf_wptr - buf_rptr);
						state <= 1;
					end
				end
				else begin
					len     <= 0;
					ce_cnt  <= 0;
					hurryup <= 0;
				end
			end
		1: if(ram_ready) begin
				ready <= 2;
				readdata <= ram_data;
				if(buf_rptr >= buf_len) buf_rptr <= buf_rptr - buf_len;
				state <= 0;
			end
        2: begin
                // Retire only the pre-reset transaction; never enqueue its
                // data as post-reset PCM. No new request toggle in this state.
                // Establish the reset discard boundary while waiting, so new
                // producer demand after that boundary survives a delayed DDR.
                if(!ce_sample && !got_first) begin
                    buf_rptr <= buf_wptr;
                    got_first <= 1;
                end
                if(ram_ready) state <= 0;
           end
		endcase
	end
end


always @(posedge clk) begin

	ce_sample <= 0;
	acc <= acc + 48000 + {hurryup,6'd0};
	if(acc >= CLK_RATE) begin
		acc <= acc - CLK_RATE;
		ce_sample <= 1;
	end
end

endmodule

// Source-owned SPI descriptor publication. Stock playback, reply and sample CE
// remain unchanged above. A descriptor is latest state, not a packet FIFO.
// With 100MHz maximum SCK and 24.576MHz running audio, complete packets are
// >=1280ns apart. Inactive-bank invalidation starts >=310ns before overwrite.
// The asynchronous permit clear survives a stopped audio clock; release takes
// two audio edges plus one synchronous validity edge. Raw bank samples cannot
// be consumed before settling. Final publication needs no subsequent SPI edge.
// Timing bounds and exact CDC scopes: constraints/seicro_alsa_cdc.sdc.
// Behavioral/negative evidence: build/timing_resume_20261030/alsa_banked01.
module seicro_alsa_rx(input spi_ss,spi_sck,spi_mosi,clk, output reg [60:0] descriptor=0, output reg [6:0] spicnt=0);
reg [7:0] spi_byte=0;
reg [28:0] addr=0;
reg [15:0] len=0,wptr=0;
(* preserve *) reg [60:0] bank0=0,bank1=0;
(* preserve *) reg published_bank=0,guard0=0,guard1=0;
wire [7:0] rx_byte={spi_byte[6:0],spi_mosi};
always @(posedge spi_sck or posedge spi_ss) begin
 if(spi_ss)begin spicnt<=0;guard0<=0;guard1<=0;end
 else begin
  spi_byte<=rx_byte;
  spicnt<=spicnt+1'b1;
  if(spicnt[2:0]==7)case(spicnt[6:3])
   0:addr[4:0]<=rx_byte[7:3];
   1:addr[12:5]<=rx_byte;
   2:addr[20:13]<=rx_byte;
   3:addr[28:21]<=rx_byte;
   4:len[4:0]<=rx_byte[7:3];
   5:len[12:5]<=rx_byte;
   6:len[15:13]<=rx_byte[2:0];
   8:wptr[4:0]<=rx_byte[7:3];
   9:wptr[12:5]<=rx_byte;
   10:wptr[15:13]<=rx_byte[2:0];
  endcase
  if(spicnt==96)begin if(published_bank)guard0<=1;else guard1<=1;end
  if(&spicnt)begin
   if(published_bank)begin bank0<={wptr,len,addr};guard0<=0;end
   else begin bank1<={wptr,len,addr};guard1<=0;end
   published_bank<=~published_bank;
  end
 end
end
(* preserve,altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] permit0=0,permit1=0;
always @(posedge clk or posedge guard0)if(guard0)permit0<=0;else permit0<={permit0[0],1'b1};
always @(posedge clk or posedge guard1)if(guard1)permit1<=0;else permit1<={permit1[0],1'b1};
(* preserve *) reg valid0=0,valid1=0;
(* preserve *) reg [60:0] sample0=0,sample1=0;
(* preserve,altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg bank_meta=0,bank_sync=0;
always @(posedge clk)begin
 bank_meta<=published_bank;bank_sync<=bank_meta;
 sample0<=bank0;sample1<=bank1;
 valid0<=permit0[1];valid1<=permit1[1];
 if(bank_sync)begin if(valid1)descriptor<=sample1;end
 else if(valid0)descriptor<=sample0;
end
endmodule
