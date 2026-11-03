// Boomrang / liberate planar GFX address helpers (MAME liberate.cpp layouts)
`ifndef YELLOWCAB_GFX_DECODE_SV
`define YELLOWCAB_GFX_DECODE_SV

package yellowcab_gfx;

  localparam int GFX1_PLANE = 'h4000;

  // FG 8×8×3 planar: plane p at p*$4000, tile code*8 + y
  function automatic [15:0] fg_addr;
    input [10:0] code;
    input [2:0]  py;
    input [1:0]  plane;
    begin
      fg_addr = (16'(plane) * 16'(GFX1_PLANE)) + {2'b0, code, 3'b000} + {13'd0, py};
    end
  endfunction

  // Sprite 16×16×3: 32 bytes/tile/plane; left half (lx<8) at +16
  function automatic [15:0] sprite_addr;
    input [8:0] code;
    input [3:0] ly;
    input       left_half;
    input [1:0] plane;
    begin
      sprite_addr = (16'(plane) * 16'(GFX1_PLANE))
                  + {2'b0, code, 5'b00000}
                  + (left_half ? 16'd16 : 16'd0)
                  + {12'd0, ly};
    end
  endfunction

  // back_scan: logical (col,row) → tile_index
  function automatic [9:0] back_scan;
    input [4:0] col;
    input [4:0] row;
    begin
      back_scan = {6'd0, row[3:0]}
                + {2'd0, (4'd15 - col[3:0]), 4'd0}
                + {row[4], 9'd0}
                + {1'b0, col[4], 8'd0};
    end
  endfunction

  // user1 paged index from tile_index + io pages 2..5 (mask to 16K on use)
  function automatic [15:0] user1_index;
    input [9:0] tile_index;
    input [7:0] page_tl, page_tr, page_bl, page_br;
    reg   [7:0] page;
    begin
      if (tile_index[8])
        page = tile_index[9] ? page_br : page_bl;
      else
        page = tile_index[9] ? page_tr : page_tl;
      user1_index = {page, tile_index[7:0]};
    end
  endfunction

  // BG x bit offset inside 16×16 packed tile
  function automatic [4:0] bg_x_bit;
    input [3:0] lx;
    begin
      case (lx[3:2])
        2'd0: bg_x_bit = 5'(24 + lx[1:0]);
        2'd1: bg_x_bit = 5'(16 + lx[1:0]);
        2'd2: bg_x_bit = 5'(8  + lx[1:0]);
        default: bg_x_bit = 5'(lx[1:0]);
      endcase
    end
  endfunction

  // Absolute bit address in gfx2 (needs 18 bits — plane offs up to 0x20004)
  // tiles1 MSB..LSB: 4, 0, 0x4000*8+4
  // tiles2 MSB..LSB: 0x2000*8+4, 0x2000*8, 0x4000*8
  // Byte index = addr[17:3]. MAME drawgfx: bit = (0x80 >> (addr & 7)) — MSB-first!
  function automatic [17:0] bg_bit_addr;
    input [6:0]  code;
    input [3:0]  lx, ly;
    input [17:0] plane_off;
    reg   [17:0] abs_bit;
    begin
      abs_bit = {2'b0, code, 9'd0}
              + plane_off
              + {13'd0, bg_x_bit(lx)}
              + {9'd0, ly, 5'd0};
      bg_bit_addr = abs_bit;
    end
  endfunction

  // MAME drawgfx.cpp: src[bitnum/8] & (0x80 >> (bitnum % 8)) → MSB-first
  function automatic [2:0] mame_bit;
    input [2:0] bitnum_lo;
    begin
      mame_bit = 3'd7 - bitnum_lo;
    end
  endfunction

  function automatic [2:0] pack3;
    input b2, b1, b0;
    begin
      pack3 = {b2, b1, b0};
    end
  endfunction

endpackage

`endif
