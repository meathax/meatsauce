// Modified for NightSlashers_MiSTer (DECO156 ARM: 26-bit, irq, boot/wishbone fixes): Umberto Parisi (rmonic79)
//////////////////////////////////////////////////////////////////
//                                                              //
//  Wishbone master interface for the Amber core                //
//                                                              //
//  This file is part of the Amber project                      //
//  http://www.opencores.org/project,amber                      //
//                                                              //
//  Description                                                 //
//  Turns memory access requests from the execute stage and     //
//  cache into wishbone bus cycles. For 4-word read requests    //
//  from the cache and swap accesses ( read followed by write   //
//  to the same address) from the execute stage,                //
//  a block transfer is done. All other requests result in      //
//  single word transfers.                                      //
//                                                              //
//  Write accesses can be done in a single clock cycle on       //
//  the wishbone bus, is the destination allows it. The         //
//  next transfer will begin immediately on the                 //
//  next cycle on the bus. This looks like a block transfer     //
//  and does hold ownership of the wishbone bus, preventing     //
//  the other master ( the ethernet MAC) from gaining           //
//  ownership between those two cycles. But otherwise it would  //
//  be necessary to insert a wait cycle after every write,      //
//  slowing down the performance of the core by around 5 to     //
//  10%.                                                        //
//                                                              //
//  Author(s):                                                  //
//      - Conor Santifort, csantifort.amber@gmail.com           //
//                                                              //
//////////////////////////////////////////////////////////////////
//                                                              //
// Copyright (C) 2010 Authors and OPENCORES.ORG                 //
//                                                              //
// This source file may be used and distributed without         //
// restriction provided that this copyright statement is not    //
// removed from the file and that any derivative work contains  //
// the original copyright notice and the associated disclaimer. //
//                                                              //
// This source file is free software; you can redistribute it   //
// and/or modify it under the terms of the GNU Lesser General   //
// Public License as published by the Free Software Foundation; //
// either version 2.1 of the License, or (at your option) any   //
// later version.                                               //
//                                                              //
// This source is distributed in the hope that it will be       //
// useful, but WITHOUT ANY WARRANTY; without even the implied   //
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      //
// PURPOSE.  See the GNU Lesser General Public License for more //
// details.                                                     //
//                                                              //
// You should have received a copy of the GNU Lesser General    //
// Public License along with this source; if not, download it   //
// from http://www.opencores.org/lgpl.shtml                     //
//                                                              //
//////////////////////////////////////////////////////////////////


module a23_wishbone
(
input                       i_clk,
input                       i_reset,

// Core Accesses to Wishbone bus
input                       i_select,
input       [31:0]          i_write_data,
input                       i_write_enable,
input       [3:0]           i_byte_enable,    // valid for writes only
input                       i_data_access,
input                       i_exclusive,      // high for read part of swap access
input       [31:0]          i_address,
output                      o_stall,
output      [31:0]          o_read_data,

// Cache Accesses to Wishbone bus
input                       i_cache_req,

// Wishbone Bus
output reg  [31:0]          o_wb_adr = 'd0,
output reg  [3:0]           o_wb_sel = 'd0,
output reg                  o_wb_we  = 'd0,
input       [31:0]          i_wb_dat,
output reg  [31:0]          o_wb_dat = 'd0,
output reg                  o_wb_cyc = 'd0,
output reg                  o_wb_stb = 'd0,
input                       i_wb_ack,
input                       i_wb_err

);



// OSMAN adaptation, 2026-10-02: synchronous cache-disabled transactions.
// The original buffered write path reissued a stalled STM beat and never
// released it with external wait states. All access types now wait for their
// own ACK. Completed tuples remain acknowledged internally until execute
// presents another request, making a CE gap harmless for reads AND writes.
reg completed = 1'b0;
reg [31:0] completed_addr = 32'd0;
reg [31:0] completed_data = 32'd0;
reg [3:0] completed_be = 4'd0;
reg completed_we = 1'b0;
reg [31:0] read_data = 32'd0;
wire [3:0] requested_be = i_write_enable ? i_byte_enable : 4'hf;
wire same_completed = completed && i_select &&
    completed_addr == i_address && completed_we == i_write_enable &&
    completed_be == requested_be && (!i_write_enable || completed_data == i_write_data);
// Private OSMAN immutable-ROM transport cache; architectural cache stays off.
// Eligibility uses wrapper physical address[25:0]; upper CPU address bits alias.
reg [31:0] rom_data [0:31];
reg [11:0] rom_tag [0:31];
reg [31:0] rom_valid = 32'd0;
reg pending_rom_read = 1'b0;
reg [4:0] pending_rom_index = 5'd0;
reg [11:0] pending_rom_tag = 12'd0;
wire rom_eligible = i_select && !i_reset && !i_write_enable &&
    !i_exclusive && !i_cache_req && i_address[25:19] == 7'd0;
wire rom_hit = rom_eligible && !o_wb_stb && !o_wb_cyc &&
    rom_valid[i_address[6:2]] && rom_tag[i_address[6:2]] == i_address[18:7];
wire acknowledged = o_wb_stb && i_wb_ack;
assign o_stall = i_select && !(same_completed || acknowledged || rom_hit);
assign o_read_data = acknowledged ? i_wb_dat : same_completed ? read_data :
    rom_hit ? rom_data[i_address[6:2]] : read_data;

always @(posedge i_clk) begin
    if (i_reset) begin
        o_wb_adr <= 32'd0;
        o_wb_sel <= 4'd0;
        o_wb_we <= 1'b0;
        o_wb_dat <= 32'd0;
        o_wb_cyc <= 1'b0;
        o_wb_stb <= 1'b0;
        completed <= 1'b0;
        read_data <= 32'd0;
        rom_valid <= 32'd0;
        pending_rom_read <= 1'b0;
    end else begin
        if (!i_select || !same_completed) completed <= 1'b0;
        if (acknowledged) begin
            // Genuine external ACK owns the latched launch tuple; capture is
            // independent of CPU CE, just like the existing completion.
            if (pending_rom_read && !i_wb_err) begin
                rom_data[pending_rom_index] <= i_wb_dat;
                rom_tag[pending_rom_index] <= pending_rom_tag;
                rom_valid[pending_rom_index] <= 1'b1;
            end
            pending_rom_read <= 1'b0;
            read_data <= i_wb_dat;
            completed <= 1'b1;
            completed_addr <= i_address;
            completed_data <= i_write_data;
            completed_be <= requested_be;
            completed_we <= i_write_enable;
            o_wb_stb <= 1'b0;
            o_wb_cyc <= i_exclusive;
        end else if (rom_hit) begin
            read_data <= rom_data[i_address[6:2]];
            completed <= 1'b1;
            completed_addr <= i_address;
            completed_data <= i_write_data;
            completed_be <= requested_be;
            completed_we <= 1'b0;
        end else if (!o_wb_stb && i_select && !same_completed) begin
            pending_rom_read <= rom_eligible && !o_wb_cyc;
            pending_rom_index <= i_address[6:2];
            pending_rom_tag <= i_address[18:7];
            o_wb_adr <= {i_address[31:2],
                requested_be == 4'b0010 ? 2'd1 :
                requested_be == 4'b0100 || requested_be == 4'b1100 ? 2'd2 :
                requested_be == 4'b1000 ? 2'd3 : 2'd0};
            o_wb_sel <= requested_be;
            o_wb_we <= i_write_enable;
            o_wb_dat <= i_write_data;
            o_wb_cyc <= 1'b1;
            o_wb_stb <= 1'b1;
        end
    end
end
// i_cache_req must stay zero: the staged a23_fetch has no cache instance.
endmodule
