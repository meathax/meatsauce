// Wave family tile-row line renderer (BG/FG MODE=0, TX MODE=1). Renders one output row into the
// WRITE bank of a 2-bank line buffer while the other bank is scanned. ROM access is one aligned 32-bit
// word per 8-pixel tile run (packed 4bpp: word = code*8 + (y&7), nibble n at bits 4n) over a req/ack toggle port.
module wave_tile_line #(parameter MODE=0, parameter TRANSP=0)(
  input clk, input reset,
  input start, input [7:0] row, input [8:0] sx, input [7:0] sy, input flip,
  output reg busy,
  output reg [10:0] ram_addr, input [7:0] ram_q,
  output reg rom_req = 1'b0, input rom_ack, output [10:0] rom_addr, input [31:0] rom_data,
  input wbank, input [8:0] rd_x, output reg [7:0] rd_q);   // {opaque, grp3, pen4}
  reg [7:0] lb0 [0:287]; reg [7:0] lb1 [0:287];
  reg wen; reg [8:0] wa; reg [7:0] wd;
  always @(posedge clk) begin
    if (wen) begin if (wbank) lb1[wa] <= wd; else lb0[wa] <= wd; end
    rd_q <= wbank ? lb0[rd_x] : lb1[rd_x];
  end
  localparam IDLE=0, ADR=1, RAMW=2, CAP=3, ROMW=4, PIX=5, RAMW2=6;
  reg [2:0] st; reg [8:0] x; reg [7:0] myr; reg [8:0] mx; reg [3:0] cnt, j; reg [7:0] code; reg [31:0] word; reg opq_bank;
  assign rom_addr = {code, myr[2:0]};
  // MODE 0: mx=((flip?256-x:x-15)+sx)&511, my=((flip?247-row:row)+sy)&255
  // MODE 1: mx= flip?287-x:x ; my= flip? ((207-row) mod 224) : row
  wire [8:0] mx0 = (MODE==0) ? ((flip ? (9'd256 - x) : (x - 9'd15)) + sx) : (flip ? (9'd287 - x) : x);
  wire [7:0] my0 = (MODE==0) ? ((flip ? (8'd247 - row) : row) + sy) : (flip ? ((row > 8'd207) ? (8'd207 - row + 8'd224) : (8'd207 - row)) : row);
  wire [5:0] col = mx0[8:3] - 6'd2;
  wire [3:0] runlen = flip ? ({1'b0, mx0[2:0]} + 4'd1) : (4'd8 - {1'b0, mx0[2:0]});
  wire [8:0] left = 9'd288 - x;
  wire [8:0] mxj = flip ? (mx - {5'b0, j}) : (mx + {5'b0, j});
  wire [3:0] pen = word[{mxj[2:0], 2'b00} +: 4];
  wire opq = (MODE==0) ? ((TRANSP==0) ? 1'b1 : (pen != 4'd15)) : ((pen != 4'd15) | opq_bank);
  always @(posedge clk) begin
    wen <= 0;
    if (reset) begin st <= IDLE; busy <= 0; rom_req <= rom_ack; end
    else case (st)
      IDLE: if (start) begin busy <= 1; x <= 0; st <= ADR; end
      ADR: begin
        myr <= my0; mx <= mx0; cnt <= (left < {5'b0, runlen}) ? left[3:0] : runlen;
        if (MODE==0) ram_addr <= {mx0[8:3], my0[7:3]}; else begin ram_addr <= {col[5], col[4:0], my0[7:3]}; opq_bank <= col[5]; end
        st <= RAMW;
      end
      // The shared RAM registers the address, then returns its synchronous read.
      // ADR changes ram_addr after its edge; capture only after both RAM stages.
      RAMW: st <= RAMW2;
      RAMW2: st <= CAP;
      CAP: begin code <= ram_q; st <= ROMW; rom_req <= ~rom_req; end
      ROMW: if (rom_ack == rom_req) begin word <= rom_data; j <= 0; st <= PIX; end
      PIX: begin
        wen <= 1; wa <= x + {5'b0, j}; wd <= {opq, (MODE==1) ? code[7:5] : 3'b000, pen};
        j <= j + 4'd1;
        if (j + 4'd1 == cnt) begin
          if (x + {5'b0, cnt} >= 9'd288) begin busy <= 0; st <= IDLE; end
          else begin x <= x + {5'b0, cnt}; st <= ADR; end
        end
      end
      default: st <= IDLE;
    endcase
  end
endmodule
