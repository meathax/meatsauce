// SPDX-License-Identifier: GPL-3.0-or-later
// Standard hiscore indices overlap JTFRAME cartridge/debug dispatch.
module dfjail_ioctl_route(
 input [15:0] index,input download,upload,wr,
 output core_download,core_upload,core_wr,
 output score_download,score_upload,score_wr
);
wire score=(index==16'd3)||(index==16'd4);
assign core_download=download && !score;
assign core_upload=upload && !score;
assign core_wr=wr && !score;
assign score_download=download && score;
assign score_upload=upload && score;
assign score_wr=wr && score;
endmodule
