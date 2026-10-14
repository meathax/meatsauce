/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 4-2-2024 */

module jt053246_dma(
    input             rst,
    input             clk,
    input             pxl2_cen,

    input             mode8,
    input             dma_en,
    input             dma_trig,
    input             k44_en,   // enable k053244/5 mode (default k053246/7)
    input             lut256,   // k44 mode only: scan the full 256-entry table
                                // (GX975 Escape Kids uses a 053246-style
                                // 256-entry LUT with the k44 register set)
    input             simson,

    input             hs,
    input             lvbl,

    // External RAM
    output reg [13:1] dma_addr, // up to 16 kB
    input      [15:0] dma_data,
    output reg        dma_bsy,    

    output            dma_weh,
    output            dma_wel,
    output     [11:1] dma_wr_addr,
    output            dma_wr_bank,
    output            scan_bank,
    output     [15:0] dma_din,
    output reg        flicker
);

parameter K55673=0, K55673_DESC_SORT=0, EDGE_TRIGGER=0;

wire        dma_we, hs_pos, clear_last;
reg  [ 1:0] lvbl_sh;
reg         gx_active_bank, gx_write_bank, gx_commit_pending;
reg  [11:1] dma_bufa;
reg  [15:0] dma_bufd;
wire [ 7:0] sort_24x, sort_673;
reg         dma_clr, dma_wait, dma_ok, dma_44, hsl;

localparam [3:0] GX_IDLE            = 4'd0,
                 GX_CLEAR           = 4'd1,
                 GX_COUNT_ADDR      = 4'd2,
                 GX_COUNT_WAIT      = 4'd3,
                 GX_COUNT_SLOT      = 4'd4,
                 GX_COUNT_WRITE     = 4'd5,
                 GX_PREFIX_ADDR     = 4'd6,
                 GX_PREFIX_WAIT     = 4'd7,
                 GX_PREFIX_WRITE    = 4'd8,
                 GX_COPY_HEAD_ADDR  = 4'd9,
                 GX_COPY_HEAD_WAIT  = 4'd10,
                 GX_COPY_SLOT_WAIT  = 4'd11,
                 GX_COPY_SLOT_WRITE = 4'd12,
                 GX_COPY_WORD_WAIT  = 4'd13,
                 GX_COPY_WORD_WRITE = 4'd14,
                 GX_COUNT_SLOT_WAIT = 4'd15;

reg  [ 3:0] gx_state;
reg  [ 7:0] gx_src, gx_prefix, gx_dest;
reg  [ 2:0] gx_word;
reg  [ 8:0] gx_running, zslot_q;
reg  [15:0] gx_header;
reg  [ 7:0] zslot_addr;
reg         gx_enabled;
reg         gx_we;
reg  [10:0] gx_waddr;
reg  [15:0] gx_wdata;

(* ramstyle = "MLAB, no_rw_check" *) reg [8:0] zslot [0:255];
wire [7:0] zslot_mem_addr = gx_state==GX_CLEAR ? dma_addr[8:1] : zslot_addr;
wire       zslot_clear_we = gx_state==GX_CLEAR && dma_addr[11:9]==0;
wire       zslot_count_we = gx_state==GX_COUNT_WRITE && gx_enabled;
wire       zslot_prefix_we = gx_state==GX_PREFIX_WRITE;
wire       zslot_copy_we = gx_state==GX_COPY_SLOT_WRITE && gx_enabled;
wire       zslot_we = zslot_clear_we | zslot_count_we |
                      zslot_prefix_we | zslot_copy_we;
wire [8:0] zslot_din = zslot_clear_we  ? 9'd0 :
                       zslot_count_we  ? zslot_q + 9'd1 :
                       zslot_prefix_we ? gx_running : zslot_q + 9'd1;

assign dma_wel = dma_we & ~dma_wr_addr[1];
assign dma_weh = dma_we &  dma_wr_addr[1];

assign dma_din     = lut256 ? gx_wdata : (dma_clr ? 16'h0 : dma_bufd);
assign dma_we      = lut256 ? gx_we : (dma_clr | dma_ok);
assign dma_wr_addr = lut256 ? gx_waddr : (dma_clr ? dma_addr[11:1] : dma_bufa);
assign dma_wr_bank = lut256 ? gx_write_bank : 1'b0;
assign scan_bank   = lut256 ? gx_active_bank : 1'b0;
assign hs_pos  = hs & ~hsl;
wire frame_start = hs_pos && lvbl && !lvbl_sh[0];
assign clear_last = k44_en ? (lut256 ? &dma_addr[11:1] : &dma_addr[10:1]) :
                             &dma_addr[11:1];

assign sort_673 = dma_data[7:0]^{8{K55673_DESC_SORT[0]}};
assign sort_24x = lut256 ? dma_data[7:0] :
                   { ~k44_en & dma_data[7], k44_en ? dma_data[6:0] : ~dma_data[6:0]};

always @* begin
    gx_we    = 0;
    gx_waddr = 0;
    gx_wdata = 0;
    case( gx_state )
        GX_CLEAR: begin
            gx_we    = 1;
            gx_waddr = dma_addr[11:1];
        end
        GX_COPY_SLOT_WRITE: if( gx_enabled ) begin
            gx_we    = 1;
            gx_waddr = {zslot_q[7:0],3'd0};
            gx_wdata = gx_header;
        end
        GX_COPY_WORD_WRITE: if( gx_enabled ) begin
            gx_we    = 1;
            gx_waddr = {gx_dest,gx_word};
            gx_wdata = dma_data;
        end
        default:;
    endcase
end

always @(posedge clk) if( pxl2_cen ) begin
    zslot_q <= zslot[zslot_mem_addr];
    if( zslot_we ) zslot[zslot_mem_addr] <= zslot_din;
end

// DMA logic
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        dma_44 <= 0;
    end else begin
        if( dma_bsy  ) dma_44 <= 0;
        if( dma_trig ) dma_44 <= 1;
    end
end

reg trigger_two_lines_after_lvbl, trigger_at_dmaen, trigger, dmaen_l;

always @* begin
    trigger_two_lines_after_lvbl = dma_en && (lvbl_sh==2'b10 && hs_pos);
    trigger_at_dmaen = ~dma_en & dmaen_l;
    trigger = EDGE_TRIGGER==1 ? trigger_at_dmaen : trigger_two_lines_after_lvbl;
end

always @(posedge clk) if(pxl2_cen) begin
    dmaen_l <= dma_en;
end

always @(posedge clk) begin
    if( rst ) begin
        dma_bsy  <= 0;
        dma_clr  <= 0;
        dma_wait <= 0;
        dma_addr <= 0;
        dma_bufa <= 0;
        dma_bufd <= 0;
        dma_bsy  <= 0;
        dma_wait <= 0;
        hsl      <= 0;
        flicker  <= 0;
        gx_state <= GX_IDLE;
        gx_src   <= 0;
        gx_prefix<= 0;
        gx_dest  <= 0;
        gx_word  <= 0;
        gx_running <= 0;
        gx_header  <= 0;
        zslot_addr <= 0;
        gx_enabled <= 0;
        lvbl_sh    <= 0;
        gx_active_bank    <= 0;
        gx_write_bank     <= 1;
        gx_commit_pending <= 0;
    end else if( pxl2_cen ) begin
        hsl <= hs;
        if( hs_pos ) begin
            lvbl_sh    <= lvbl_sh<<1;
            lvbl_sh[0] <= lvbl;
        end
        if( frame_start && gx_commit_pending ) begin
            gx_active_bank    <= gx_write_bank;
            gx_commit_pending <= 0;
        end
        if(!dma_bsy && (trigger || dma_44) ) begin
            dma_bsy  <= 1;
            dma_clr  <= !lut256;
            dma_wait <= !lut256 && !k44_en && mode8; // 8-bit speed: 595us, 16-bit: 297.5us
            flicker  <= ~flicker;
            dma_addr <= 0;
            if( lut256 ) begin
                gx_write_bank <= ~gx_active_bank;
                gx_state   <= GX_CLEAR;
                gx_src     <= 0;
                gx_running <= 0;
                gx_enabled <= 0;
            end
        end
        if( !dma_bsy ) begin
            dma_addr <= 0;
            dma_bufa <= 0;
            dma_ok   <= 0;
        end else if( lut256 ) begin
            case( gx_state )
                GX_CLEAR: begin
                    if( &dma_addr[11:1] ) begin
                        dma_addr <= 0;
                        gx_src   <= 0;
                        gx_state <= GX_COUNT_ADDR;
                    end else begin
                        dma_addr[11:1] <= dma_addr[11:1] + 1'd1;
                    end
                end
                GX_COUNT_ADDR: begin
                    dma_addr <= {2'b00,gx_src,3'd0};
                    gx_state <= GX_COUNT_WAIT;
                end
                GX_COUNT_WAIT: gx_state <= GX_COUNT_SLOT;
                GX_COUNT_SLOT: begin
                    gx_enabled <= dma_data[15];
                    zslot_addr <= dma_data[7:0];
                    gx_state   <= GX_COUNT_SLOT_WAIT;
                end
                GX_COUNT_SLOT_WAIT: gx_state <= GX_COUNT_WRITE;
                GX_COUNT_WRITE: begin
                    if( &gx_src ) begin
                        gx_prefix  <= 0;
                        gx_running <= 0;
                        gx_state   <= GX_PREFIX_ADDR;
                    end else begin
                        gx_src   <= gx_src + 1'd1;
                        gx_state <= GX_COUNT_ADDR;
                    end
                end
                GX_PREFIX_ADDR: begin
                    zslot_addr <= gx_prefix;
                    gx_state   <= GX_PREFIX_WAIT;
                end
                GX_PREFIX_WAIT: gx_state <= GX_PREFIX_WRITE;
                GX_PREFIX_WRITE: begin
                    gx_running <= gx_running + zslot_q;
                    if( &gx_prefix ) begin
                        gx_src   <= 0;
                        gx_state <= GX_COPY_HEAD_ADDR;
                    end else begin
                        gx_prefix <= gx_prefix + 1'd1;
                        gx_state  <= GX_PREFIX_ADDR;
                    end
                end
                GX_COPY_HEAD_ADDR: begin
                    dma_addr <= {2'b00,gx_src,3'd0};
                    gx_state <= GX_COPY_HEAD_WAIT;
                end
                GX_COPY_HEAD_WAIT: begin
                    gx_header  <= dma_data;
                    gx_enabled <= dma_data[15];
                    zslot_addr <= dma_data[7:0];
                    gx_state   <= GX_COPY_SLOT_WAIT;
                end
                GX_COPY_SLOT_WAIT: gx_state <= GX_COPY_SLOT_WRITE;
                GX_COPY_SLOT_WRITE: begin
                    if( gx_enabled ) begin
                        gx_dest <= zslot_q[7:0];
                        gx_word <= 3'd1;
                        dma_addr <= {2'b00,gx_src,3'd1};
                        gx_state <= GX_COPY_WORD_WAIT;
                    end else if( &gx_src ) begin
                        dma_bsy  <= 0;
                        gx_commit_pending <= 1;
                        gx_state <= GX_IDLE;
                    end else begin
                        gx_src   <= gx_src + 1'd1;
                        gx_state <= GX_COPY_HEAD_ADDR;
                    end
                end
                GX_COPY_WORD_WAIT: gx_state <= GX_COPY_WORD_WRITE;
                GX_COPY_WORD_WRITE: begin
                    if( gx_word==3'd6 ) begin
                        if( &gx_src ) begin
                            dma_bsy  <= 0;
                            gx_commit_pending <= 1;
                            gx_state <= GX_IDLE;
                        end else begin
                            gx_src   <= gx_src + 1'd1;
                            gx_state <= GX_COPY_HEAD_ADDR;
                        end
                    end else begin
                        gx_word <= gx_word + 1'd1;
                        dma_addr <= {2'b00,gx_src,gx_word + 1'd1};
                        gx_state <= GX_COPY_WORD_WAIT;
                    end
                end
                default: begin
                    dma_bsy  <= 0;
                    gx_state <= GX_IDLE;
                end
            endcase
        end else if( dma_clr ) begin // copy by priority order
            dma_addr[11:1] <= dma_addr[11:1] + 1'd1;
            dma_clr <= ~clear_last;
            if( k44_en && !lut256 ) dma_addr[11]<=0;
            if( &dma_addr[11:1] && dma_wait ) dma_addr[11:1] <= 'h218; // extra 126us wait
        end else if(dma_wait) begin // extra time to match the original speed
            { dma_wait, dma_addr[11:1] } <= { 1'b1, dma_addr[11:1] } + 1'd1;
        end else begin
            dma_bufd <= dma_data;
            if( k44_en ) dma_addr[13:11] <= 0;
            if( dma_addr[3:1]==0 ) begin
                // the sprite at priority 0 in the Simpsons creates a problem in scene simson/4
                // I was skipping it before, but priority 0 is used in Vendetta and it must take priority
                // over the rest (see scene vendetta/3)
                // LUT half as big for 053244 and reversed order
                dma_bufa <= { K55673==1 ? sort_673 : sort_24x, 3'd0 };
                dma_ok   <= dma_data[15] && (dma_data[7:0]!=0 || !simson);
            end
            dma_addr[12:1] <= dma_addr[12:1] + 1'd1;
            dma_bufa[ 3:1] <= dma_addr[3:1];
            if( dma_addr[3:1]==6 ) begin
                dma_addr[12:1] <= dma_addr[12:1] + 12'd2; // skip 7
                dma_bsy <= !(&dma_addr[10:2] && ((k44_en && (dma_addr[11] || !lut256)) || &dma_addr[12:11]));
            end
        end
    end
end

endmodule
