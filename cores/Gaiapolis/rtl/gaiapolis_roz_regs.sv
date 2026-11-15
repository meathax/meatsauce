// SPDX-License-Identifier: GPL-3.0-or-later
// MAME 0.289 mystwarr.cpp/gaiapols_map and mystwarr_v.cpp ROZ readback.
// Real registers, line RAM and raw ROM reads; rendering uses the second ports.
module gaiapolis_roz_regs(
    input wire monster,
    input logic clk, rst,
    // Device-local CPU word address; the board decoder owns upper/A0 bits.
    input logic [20:1] addr,
    input logic wr,
    input logic [1:0] byte_mask,
    input logic [15:0] din,
    input logic cs_ctrl, cs_line, cs_clip, cs_enable,
    input logic cs_map0, cs_map1, cs_tiles,
    output logic [15:0] cpu_dout,
    output logic cpu_ready,
    output logic [19:0] map_addr,
    output logic map_cs,
    input logic [7:0] map_data,
    input logic map_ok,
    output logic [20:0] char_addr,
    output logic char_cs,
    input logic [7:0] char_data,
    input logic char_ok,
    input logic [3:0] render_ctrl_addr,
    output logic [15:0] render_ctrl_data,
    input logic [10:0] render_line_addr,
    output logic [15:0] render_line_data,
    output logic enabled, clip_enabled,
    output logic [15:0] clip_rect
);
    logic [15:0] ctrl[0:15];
    logic [7:0] line_hi[0:2047], line_lo[0:2047];
    logic [15:0] line_dout;
    logic [1:0] bank;
    logic [7:0] map_high;
    logic [17:0] map_offset;
    logic [20:0] tile_offset;
    logic [2:0] state;
    logic [1:0] kind;
    localparam logic [2:0] IDLE=3'd0, FIRST=3'd1, GAP=3'd2,
                           SECOND=3'd3, DONE=3'd4;
    wire request = cs_map0 || cs_map1 || cs_tiles;

    always_ff @(posedge clk) begin
        line_dout <= {line_hi[addr[11:1]],line_lo[addr[11:1]]};
        render_line_data <= {line_hi[render_line_addr],line_lo[render_line_addr]};
        render_ctrl_data <= ctrl[render_ctrl_addr];
        if (rst) begin
            enabled <= 1'b0;
            clip_enabled <= 1'b0;
            clip_rect <= 16'd0;
            bank <= 2'd0;
            for (int i=0; i<16; i++) ctrl[i] <= 16'd0;
        end else begin
            if (cs_ctrl && wr) begin
                if (byte_mask[1]) ctrl[addr[4:1]][15:8] <= din[15:8];
                if (byte_mask[0]) ctrl[addr[4:1]][7:0] <= din[7:0];
            end
            if (cs_line && wr) begin
                if (byte_mask[1]) line_hi[addr[11:1]] <= din[15:8];
                if (byte_mask[0]) line_lo[addr[11:1]] <= din[7:0];
            end
            if (cs_enable && wr && byte_mask[1]) begin
                enabled <= din[8];
                bank <= din[15:14];
            end
            if (cs_clip && wr) begin
                if (!addr[1]) begin
                    if (byte_mask[1]) clip_rect[15:8] <= din[15:8];
                    if (byte_mask[0]) clip_rect[7:0] <= din[7:0];
                end else if (byte_mask[1]) clip_enabled <= din[8];
            end
        end
    end

    // K053936 ROM windows are byte sources on a word CPU bus. The code
    // window needs two independent byte requests; drop CS in between so a
    // cached/scheduled SDRAM slot cannot reuse the first acknowledgement.
    always_ff @(posedge clk) begin
        if (rst || !request) begin
            state <= IDLE;
            kind <= 2'd0;
            map_offset <= 18'd0;
            tile_offset <= 21'd0;
            map_high <= 8'd0;
            rom_dout <= 16'd0;
        end else case (state)
            IDLE: begin
                kind <= cs_tiles ? 2'd2 : cs_map1 ? 2'd1 : 2'd0;
                map_offset <= addr[18:1];
                tile_offset <= monster ? {bank[0],addr[20:1]} : {bank,addr[20:2]};
                state <= FIRST;
            end
            FIRST: begin
                if (kind == 2'd2 && char_ok) begin
                    rom_dout <= {char_data,8'h00};
                    state <= DONE;
                end else if (kind != 2'd2 && map_ok) begin
                    if (kind == 2'd1) begin
                        rom_dout <= {8'h00,map_data};
                        state <= DONE;
                    end else begin
                        map_high <= map_data;
                        state <= GAP;
                    end
                end
            end
            GAP: state <= SECOND;
            SECOND: if (map_ok) begin
                rom_dout <= {map_high,map_data};
                state <= DONE;
            end
            default: state <= DONE;
        endcase
    end
    logic [15:0] rom_dout;
    always_comb begin
        map_addr = kind == 2'd1 ? {3'd0,map_offset[17:1]} :
                   (monster ? (state == SECOND ? 20'h40000 : 20'h00000) : (state == SECOND ? 20'h60000 : 20'h20000)) + {2'd0,map_offset};
        map_cs = request && kind != 2'd2 && (state == FIRST || state == SECOND);
        char_addr = tile_offset;
        char_cs = request && kind == 2'd2 && state == FIRST;
        cpu_ready = !request || state == DONE;
        cpu_dout = cs_line ? line_dout : rom_dout;
    end
endmodule
