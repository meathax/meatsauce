// SPDX-License-Identifier: GPL-3.0-or-later
module appoooh_rom_loader #(
 parameter integer SIZE=appoooh_pkg::ROM_SIZE,
 parameter integer ROBOWRES_SIZE=appoooh_pkg::ROBOWRES_ROM_SIZE
)(
 input logic clk, cold_reset, download, wr,
 input logic [15:0] index,
 input logic [26:0] addr,
 input logic [7:0] data,
 output logic valid, error, loading, mem_wr,
 output logic [18:0] mem_addr,
 output logic [7:0] mem_data,
 output logic robowres_mode
);
 logic session, prev_download, prev_wr, selected_robowres;
 logic [15:0] session_index;
 logic [26:0] count;
 wire start=download&&!prev_download&&(index==0||index==1);
 wire transfer=download&&wr&&!prev_wr;
 wire active_robowres=session?session_index==1:index==1;
 wire [26:0] expected_size=active_robowres?27'(ROBOWRES_SIZE):27'(SIZE);
 assign loading=session||start;
 // Expose the selected game combinationally on the opening download edge so
 // a core can route a simultaneous first-byte write to the right ROM layout.
 always_comb begin
  if(start)robowres_mode=index==1;
  else if(session)robowres_mode=session_index==1;
  else robowres_mode=selected_robowres;
 end
 assign mem_wr=transfer&&(session||start)&&(index==(start?index:session_index))&&(start||!error)&&addr==(start?27'd0:count)&&addr<expected_size;
 assign mem_addr=addr[18:0];
 assign mem_data=data;
 always_ff @(posedge clk) begin
  if(cold_reset) begin valid<=0;error<=0;session<=0;prev_download<=0;prev_wr<=0;count<=0;session_index<=0;selected_robowres<=0;end
  else begin
   prev_download<=download;prev_wr<=wr;
   if(start) begin session<=1;valid<=0;error<=0;count<=0;session_index<=index;selected_robowres<=index==1;end
   if(session&&download&&index!=session_index)error<=1;
   if(transfer&&(session||start)) begin
    if(index!=(start?index:session_index)||addr!=(start?27'd0:count)||addr>=expected_size)error<=1;
    else count<=(start?27'd0:count)+27'd1;
   end
   if(session&&!download) begin
    session<=0;valid<=!error&&count==expected_size;
    if(count!=expected_size)error<=1;
   end
  end
 end
endmodule
