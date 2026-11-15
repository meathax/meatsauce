///----------------------------------------------------------------------------
//
//  Copyright 2022 Darren Olafson
//
//  MiSTer Copyright (C) 2017 Sorgelig
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
//----------------------------------------------------------------------------


// simple read-only cache 
// specificly for 68k program rom.  todo - parameterize 
module tile_cache
(
    input reset,
    input clk,

    input cache_req,
    input [19:0] cache_addr,

    output reg cache_valid,
    output [31:0] cache_data,

    input  [31:0] rom_data,
    input  rom_valid,
    
    output reg rom_req,
    output reg [19:0] rom_addr
);


// Tag and data RAMs share the same registered read address. The requester
// holds cache_addr/cache_req until cache_valid, as on the ROM interface.
reg [511:0] valid;
// Split the valid lookup across the existing IDLE/LOOKUP edges, matching
// the synchronous tag/data address launch without adding a reply cycle.
// Each bank pre-reads one of 32 resettable valid bits; LOOKUP selects the bank.
reg [15:0] valid_choices;
localparam IDLE=0, LOOKUP=1, WAIT_ROM=2, FILL=3, HIT=4, REPLY=5;
reg [2:0] state = IDLE;
reg [8:0] idx_r;
wire [8:0] idx = cache_addr[8:0];
reg [31:0] cache_din;
wire [31:0] cache_dout;
wire [10:0] tag_dout;
wire hit = valid_choices[idx_r[8:5]] && tag_dout == rom_addr[19:9];
assign cache_data = state == HIT ? cache_dout : rom_data;

genvar valid_bank;
generate for (valid_bank=0; valid_bank<16; valid_bank=valid_bank+1) begin: valid_bank_read
    always @(posedge clk) begin
        if (reset) valid_choices[valid_bank] <= 0;
        else if (cache_req && state == IDLE)
            valid_choices[valid_bank] <= valid[valid_bank*32 + idx[4:0]];
    end
end endgenerate

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        valid <= 0;
        cache_valid <= 0;
        rom_req <= 0;
    end else if (!cache_req) begin
        state <= IDLE;
        cache_valid <= 0;
        rom_req <= 0;
    end else begin
        case (state)
        IDLE: begin
            idx_r <= idx;
            rom_addr <= cache_addr;
            state <= LOOKUP;
        end
        LOOKUP: begin
            if (hit) begin
                cache_valid <= 1;
                state <= HIT;
            end else begin
                rom_req <= 1;
                state <= WAIT_ROM;
            end
        end
        WAIT_ROM: if (rom_valid) begin
            cache_din <= rom_data;
            cache_valid <= 1;
            state <= FILL;
        end
        FILL: begin
            // Both memories are written on this edge before the entry is valid.
            valid[idx_r] <= 1;
            state <= REPLY;
        end
        default: begin end
        endcase
    end
end

dual_port_ram #(.LEN(512), .DATA_WIDTH(11)) tag_ram (
    .clock_a(clk), .address_a(idx_r), .wren_a(state == FILL && !reset),
    .data_a(rom_addr[19:9]), .q_a(),
    .clock_b(clk), .address_b(idx), .wren_b(1'b0), .q_b(tag_dout)
);
dual_port_ram #(.LEN(512), .DATA_WIDTH(32)) cache_ram (
    .clock_a(clk), .address_a(idx_r), .wren_a(state == FILL && !reset),
    .data_a(cache_din), .q_a(),
    .clock_b(clk), .address_b(idx), .wren_b(1'b0), .q_b(cache_dout)
);
endmodule


module sound_cache
(
    input reset,
    input clk,

    input cache_req,
    input [18:0] cache_addr,

    output reg cache_valid,
    output [7:0] cache_data,

    input  [7:0] rom_data,
    input  rom_valid,
    
    output reg rom_req,
    output reg [18:0] rom_addr
);


reg [18:9]   tag   [511:0];
reg [511:0]  valid ;
reg [1:0]    state = 0;

reg  [8:0]   idx_r;

wire [8:0]   idx = cache_addr[8:0];
wire hit;

// if tag value matches the upper bits of the address 
// and valid then no need to pass request to sdram 
assign hit = ( tag[idx] == cache_addr[18:9] && valid[idx] == 1 && state == 1 );


assign cache_data = ( hit == 1 ) ? cache_dout : rom_data;

// Complete tag/data publication on the existing RAM-write edge.
// Reset invalidates the entry even if an old fill updates its unused tag.
always @(posedge clk) begin
    if (state == 3) tag[idx_r] <= rom_addr[18:9];
end

always @ (posedge clk) begin
    cache_valid <= ( cache_req != 0 ) && ( hit == 1 || rom_valid == 1 );
    if ( reset == 1 ) begin
        state <= 0;
        // reset bits that indicate tag is valid
        valid <= 0;
    end else begin
        // Complete a fill even when the requester drops CS before this edge.
        if (state == 3) valid[idx_r] <= 1'b1;
        // if no read request then do nothing
        if ( cache_req == 0 ) begin
            rom_req <= 0;
            state <= 1;
        end else begin
            // if there is a hit then read from cache and say we are done
            if ( hit == 1 ) begin
                rom_req <= 0;
            end else if ( state == 1 ) begin
                // read from memory

                idx_r <= idx;
                
                // we need to read from sdram
                rom_req <= 1;
                rom_addr <= cache_addr;

                // next state is wait for rom ready
                state <= 2;
                
            end else if ( state == 2 && rom_valid == 1 ) begin

                cache_din <= rom_data;
                
                state <= 3;
            end else if ( state == 3 ) begin
                state <= 0;
            end
        end
    end
end

reg  [7:0] cache_din;
wire [7:0] cache_dout;

dual_port_ram #(.LEN(512), .DATA_WIDTH(8)) cache_ram (
    .clock_a ( clk ),
    .address_a ( idx_r ),
    .wren_a ( state == 3 ),
    .data_a ( cache_din ),
    .q_a (  ),

    .clock_b ( clk ),
    .address_b ( idx ),
    .wren_b ( 0 ),
    .q_b ( cache_dout )
    );


endmodule

