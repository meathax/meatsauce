// SPDX-License-Identifier: GPL-3.0-or-later
module drmicro_rom_loader #(parameter integer SIZE=drmicro_pkg::ROM_SIZE)(
 input logic clk, cold_reset, download, wr,
 input logic [15:0] index,
 input logic [26:0] addr,
 input logic [7:0] data,
 output logic valid, error, loading, mem_wr,
 output logic [16:0] mem_addr,
 output logic [7:0] mem_data
);
 logic session, prev_download, prev_wr;
 logic [26:0] count;
 wire start=download&&!prev_download&&index==0;
 wire transfer=download&&wr&&!prev_wr;
 assign loading=session||start;
 assign mem_wr=transfer&&index==0&&(session||start)&&(start||!error)&&addr==(start?27'd0:count)&&addr<27'(SIZE);
 assign mem_addr=addr[16:0];
 assign mem_data=data;
 always_ff @(posedge clk) begin
  if(cold_reset) begin valid<=0;error<=0;session<=0;prev_download<=0;prev_wr<=0;count<=0;end
  else begin
   prev_download<=download;prev_wr<=wr;
   if(start) begin session<=1;valid<=0;error<=0;count<=0;end
   if(session&&download&&index!=0)error<=1;
   if(transfer&&(session||start)) begin
    if(index!=0||addr!=(start?27'd0:count)||addr>=27'(SIZE))error<=1;
    else count<=(start?27'd0:count)+27'd1;
   end
   if(session&&!download) begin
    session<=0;valid<=!error&&count==27'(SIZE);
    if(count!=27'(SIZE))error<=1;
   end
  end
 end
endmodule
