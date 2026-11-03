//
// hps_io.v
//
// Copyright (c) 2014 Till Harbaum <till@harbaum.org>
// Copyright (c) 2017-2026 Alexey Melnikov
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////
// altera message_off 10665

//
// Use buffer to access SD card. It's time-critical part.
//
// WIDE=1 for 16 bit file I/O
// VDNUM 1..10
// BLKSZ 0..7: 0 = 128, 1 = 256, 2 = 512(default), .. 7 = 16384

// F12KEYMOD - is modifier key requested to raise fremework menu? 
//  0 - no, F12 bring framework menu
//  1 - F12 is passed to core, F12 + (L/R)GUI key bring framework menu

//
// Project-local metrics CDC derivative; original sys is preserved.
// Original Template commit 3ea1134cf05d62c2b1db30362277a823d739ced2.
module darkmist_video_calc
(
	input clk_100,
	input clk_vid,
	input clk_sys,
	input reset,read_hold,

	input ce_pix,
	input de,
	input hs,
	input vs,
	input vs_hdmi,
	input f1,
	input new_vmode,
	input video_rotated,

	input       [4:0] par_num,
	output reg [15:0] dout
);

wire [127:0] latest_metrics;
wire metrics_valid;
reg [127:0] read_snapshot=0;
reg hold_previous=0;
darkmist_metrics_cdc metrics_cdc(
 .src_clk(clk_100),.dst_clk(clk_sys),.reset(reset),
 .src_metrics({vid_vtime_hdmi,vid_pix,vid_vtime,vid_htime}),
 .dst_metrics(latest_metrics),.dst_valid(metrics_valid)
);
always @(posedge clk_sys) begin
 if(reset) begin
  // HPS protocol state is not reset. Preserve an already-held record so a
  // burst spanning game reset cannot mix pre/post-reset halves.
  hold_previous<=read_hold;
  if(!read_hold) read_snapshot<=0;
 end
 else begin
  hold_previous<=read_hold;
  if(!read_hold || !hold_previous) read_snapshot<=latest_metrics;
 end
end

always @(posedge clk_sys) begin
	case(par_num)
		1: dout <= {video_rotated, |vid_int, vid_nres};
		2: dout <= vid_hcnt[15:0];
		3: dout <= vid_hcnt[31:16];
		4: dout <= vid_vcnt[15:0];
		5: dout <= vid_vcnt[31:16];
		6: dout <= read_snapshot[15:0];
		7: dout <= read_snapshot[31:16];
		8: dout <= read_snapshot[47:32];
		9: dout <= read_snapshot[63:48];
	  10: dout <= read_snapshot[79:64];
	  11: dout <= read_snapshot[95:80];
	  12: dout <= read_snapshot[111:96];
	  13: dout <= read_snapshot[127:112];
	  14: dout <= vid_ccnt[15:0];
	  15: dout <= vid_ccnt[31:16];
	  16: dout <= vid_pixrep;
	  17: dout <= vid_de_h;
	  18: dout <= vid_de_v;
	  19: dout <= vid_fclks[15:0];
	  20: dout <= {8'd0, vid_fclks[23:16]};
	  default dout <= 0;
	endcase
end

reg [31:0] vid_hcnt = 0;
reg [31:0] vid_vcnt = 0;
reg [31:0] vid_ccnt = 0;
reg  [7:0] vid_nres = 0;
reg  [1:0] vid_int  = 0;
reg  [7:0] vid_pixrep;
reg [15:0] vid_de_h;
reg  [7:0] vid_de_v;

// Exact clk_vid edges in one complete frame.
// Count once after startup or a timing change, then hold the result.
reg [23:0] vid_fclks = 0;

always @(posedge clk_vid) begin
	integer hcnt;
	integer vcnt;
	integer ccnt;
	reg [7:0] pcnt;
	reg [7:0] de_v;
	reg [15:0] de_h;
	reg old_vs = 0, old_hs = 0, old_hs_vclk = 0, old_de = 0, old_de_vclk = 0, old_de1 = 0, old_vmode = 0;
	reg [3:0] resto = 0;
	reg calch = 0;

	if(resto == 1) vid_fclks <= vid_fclks + 1'd1;
	if(calch & de) ccnt <= ccnt + 1;
	pcnt <= pcnt + 1'd1;

	old_hs_vclk <= hs;
	de_h <= de_h + 1'd1;
	if(old_hs_vclk & ~hs) de_h <= 1;

	old_de_vclk <= de;
	if(calch & ~old_de_vclk & de) vid_de_h <= de_h;

	if(ce_pix) begin
		old_vs <= vs;
		old_hs <= hs;
		old_de <= de;
		old_de1 <= old_de;
		pcnt <= 1;

		if(~vs & ~old_de & de) vcnt <= vcnt + 1;
		if(calch & de) hcnt <= hcnt + 1;
		if(old_de & ~de) calch <= 0;
		if(~old_de1 & old_de) vid_pixrep <= pcnt;
		if(old_hs & ~hs) de_v <= de_v + 1'd1;
		if(calch & ~old_de & de) vid_de_v <= de_v;

		if(old_vs & ~vs) begin
			vid_int <= {vid_int[0],f1};
			if(~f1) begin
				// !f1 selects the same boundary once per complete frame.
				if(hcnt && vcnt) begin
					old_vmode <= new_vmode;

					//report new resolution after timeout
					if(resto) resto <= resto + 1'd1;
					if(vid_hcnt != hcnt || vid_vcnt != vcnt || old_vmode != new_vmode) begin
						resto <= 1;
						vid_fclks <= 0;
					end
					if(&resto) vid_nres <= vid_nres + 1'd1;
					vid_hcnt <= hcnt;
					vid_vcnt <= vcnt;
					vid_ccnt <= ccnt;
				end
				vcnt <= 0;
				hcnt <= 0;
				ccnt <= 0;
				calch <= 1;
				de_v <= 0;
			end
		end
	end
end

// Resolve each asynchronous measurement input before edge/count logic.
// Keep these stages separate and unreset: producers measure through host_reset.
// Initial zeros only define power-up sampling history; reset belongs to mailbox.
(* ASYNC_REG="TRUE", preserve *) reg [1:0] vs_100_sync=0,hs_100_sync=0;
(* ASYNC_REG="TRUE", preserve *) reg [1:0] de_100_sync=0,hdmi_vs_100_sync=0;
always @(posedge clk_100) begin
    vs_100_sync<={vs_100_sync[0],vs};
    hs_100_sync<={hs_100_sync[0],hs};
    de_100_sync<={de_100_sync[0],de};
    hdmi_vs_100_sync<={hdmi_vs_100_sync[0],vs_hdmi};
end

reg [31:0] vid_htime = 0;
reg [31:0] vid_vtime = 0;
reg [31:0] vid_pix = 0;

always @(posedge clk_100) begin
	integer vtime, htime, hcnt;
	reg old_vs, old_hs, old_vs2, old_hs2, old_de, old_de2;
	reg calch = 0;

	old_vs <= vs_100_sync[1];
	old_hs <= hs_100_sync[1];

	old_vs2 <= old_vs;
	old_hs2 <= old_hs;

	vtime <= vtime + 1'd1;
	htime <= htime + 1'd1;

	if(~old_vs2 & old_vs) begin
		vid_pix <= hcnt;
		vid_vtime <= vtime;
		vtime <= 0;
		hcnt <= 0;
	end

	if(old_vs2 & ~old_vs) calch <= 1;

	if(~old_hs2 & old_hs) begin
		vid_htime <= htime;
		htime <= 0;
	end

	old_de   <= de_100_sync[1];
	old_de2  <= old_de;

	if(calch & old_de) hcnt <= hcnt + 1;
	if(old_de2 & ~old_de) calch <= 0;
end

reg [31:0] vid_vtime_hdmi;
always @(posedge clk_100) begin
	integer vtime;
	reg old_vs, old_vs2;

	old_vs <= hdmi_vs_100_sync[1];
	old_vs2 <= old_vs;

	vtime <= vtime + 1'd1;

	if(~old_vs2 & old_vs) begin
		vid_vtime_hdmi <= vtime;
		vtime <= 0;
	end
end

endmodule

