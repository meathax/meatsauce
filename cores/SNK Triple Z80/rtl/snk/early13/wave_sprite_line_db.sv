// Wave family sprite line renderer, double-buffered, 32-bit word ROM port (union version of wave_sprite_line).
// Same MAME marvins_draw_sprites equations. Renders into the WRITE bank (cleared by a 288-clock sweep at start);
// the other bank is read by rd_x (sync read). ROM: word index {plane,code,row[3:1]}, halfword = row[0].
module wave_sprite_line_db(
  input clk, input reset,
  input start, input [7:0] oy, output reg busy,
  input [8:0] sp_sx, input [7:0] sp_sy, input [7:0] split, input flip,
  output [7:0] sr_addr, input [7:0] sr_q,
  output reg rom_req = 1'b0, input rom_ack, output [12:0] rom_addr, input [31:0] rom_data,
  input wbank, input [8:0] rd_x, output reg [7:0] lo_c, hi_c, output reg lo_s, hi_s);
  reg [7:0] clo0 [0:287]; reg [7:0] clo1 [0:287]; reg [7:0] chi0 [0:287]; reg [7:0] chi1 [0:287];
  reg slo0 [0:287]; reg slo1 [0:287]; reg shi0 [0:287]; reg shi1 [0:287];
  reg wr_c, wr_s, wr_sel, wr_clr; reg [8:0] wr_a; reg [7:0] wr_cd;
  always @(posedge clk) begin
    if (wr_clr) begin
      if (wbank) begin clo1[wr_a] <= 0; chi1[wr_a] <= 0; slo1[wr_a] <= 0; shi1[wr_a] <= 0; end
      else begin clo0[wr_a] <= 0; chi0[wr_a] <= 0; slo0[wr_a] <= 0; shi0[wr_a] <= 0; end
    end else begin
      if (wr_c && !wr_sel) begin if (wbank) begin clo1[wr_a] <= wr_cd; slo1[wr_a] <= 0; end else begin clo0[wr_a] <= wr_cd; slo0[wr_a] <= 0; end end
      if (wr_c &&  wr_sel) begin if (wbank) begin chi1[wr_a] <= wr_cd; shi1[wr_a] <= 0; end else begin chi0[wr_a] <= wr_cd; shi0[wr_a] <= 0; end end
      if (wr_s && !wr_sel) begin if (wbank) slo1[wr_a] <= 1; else slo0[wr_a] <= 1; end
      if (wr_s &&  wr_sel) begin if (wbank) shi1[wr_a] <= 1; else shi0[wr_a] <= 1; end
    end
    if (wbank) begin lo_c <= clo0[rd_x]; hi_c <= chi0[rd_x]; lo_s <= slo0[rd_x]; hi_s <= shi0[rd_x]; end
    else       begin lo_c <= clo1[rd_x]; hi_c <= chi1[rd_x]; lo_s <= slo1[rd_x]; hi_s <= shi1[rd_x]; end
  end
  localparam IDLE=0, CLR=1, R0=2, R1W=3, R1=4, R2W=5, R2=6, R3W=7, R3=8, R4=9, CMP=10, FET=11, DRAW=12;
  reg [3:0] st; reg [5:0] idx, lim; reg [7:0] y8, code, x8, attr; reg [3:0] row; reg [9:0] sxs; reg fx;
  reg [2:0] fk; reg [4:0] dx; reg [15:0] h0, h1, h2; reg [1:0] plane; reg [8:0] cc;
  wire [5:0] splitq = split[7:2];
  reg [1:0] rsel;
  assign sr_addr = {idx, rsel};
  assign rom_addr = {plane, code, row[3:1]};
  wire [7:0] sya = 8'd0 - sp_sy - 8'd8 + y8;
  wire [7:0] sy8_calc = flip ? (8'd246 - sya) : sya;
  // Y and line controls are held by the parent for this render. Capture in
  // the existing attribute-fetch cycle; CMP sees the same value one cycle later.
  reg [7:0] sy8;
  wire [9:0] syv = (sy8 > 8'd240) ? ({2'b00, sy8} - 10'd256) : {2'b00, sy8};
  wire [8:0] sxa = sp_sx + 9'd286 - {1'b0, x8} + {attr[7], 8'b0};
  wire [8:0] sxb = flip ? (9'd73 - sxa) : sxa;
  wire [9:0] sxv = (sxb > 9'd496) ? ({1'b0, sxb} - 10'd512) : {1'b0, sxb};
  wire [9:0] dyv = {2'b00, oy} + 10'd8 - syv;
  wire hit = (dyv[9:4] == 6'd0);
  wire [3:0] rowv = (attr[5] ^ flip) ? ~dyv[3:0] : dyv[3:0];
  wire [3:0] xx = fx ? ~dx[3:0] : dx[3:0];
  wire [7:0] q0 = xx[3] ? h0[15:8] : h0[7:0], q1 = xx[3] ? h1[15:8] : h1[7:0], q2 = xx[3] ? h2[15:8] : h2[7:0];
  wire [2:0] penr = {q2[xx[2:0]], q1[xx[2:0]], q0[xx[2:0]]};
  wire [9:0] oxv = sxs + {5'b0, dx};
  wire inx = (oxv < 10'd288);
  wire last = (idx + 6'd1 >= lim);
  wire [15:0] hsel = row[0] ? rom_data[31:16] : rom_data[15:0];
  always @(posedge clk) begin
    wr_c <= 0; wr_s <= 0; wr_clr <= 0;
    if (reset) begin st <= IDLE; busy <= 0; rsel <= 0; plane <= 0; rom_req <= rom_ack; end
    else case (st)
      IDLE: if (start) begin busy <= 1; cc <= 0; st <= CLR; idx <= 0; lim <= (splitq > 6'd25) ? splitq : 6'd25; rsel <= 0; end
      CLR: begin wr_clr <= 1; wr_a <= cc; cc <= cc + 9'd1; if (cc == 9'd287) st <= R0; end
      // The shared early RAM registers the byte address before its synchronous
      // M10K read. Hold each selected byte for the response stage before capture.
      R0: begin rsel <= 1; st <= R1W; end
      R1W: st <= R1;
      R1: begin y8 <= sr_q; rsel <= 2; st <= R2W; end
      R2W: st <= R2;
      R2: begin code <= sr_q; rsel <= 3; st <= R3W; end
      R3W: st <= R3;
      R3: begin x8 <= sr_q; st <= R4; end
      R4: begin attr <= sr_q; sy8 <= sy8_calc; st <= CMP; end
      CMP: begin
        if (!hit) begin
          if (last) begin busy <= 0; st <= IDLE; end else begin idx <= idx + 6'd1; rsel <= 0; st <= R0; end
        end else begin row <= rowv; sxs <= sxv; fx <= flip; fk <= 0; plane <= 0; st <= FET; end
      end
      FET: begin
        // three sequential word reads (plane 0,1,2): request, wait ack, capture
        if (fk[0] == 1'b0) begin rom_req <= ~rom_req; fk <= fk + 3'd1; end
        else if (rom_ack == rom_req) begin
          case (plane) 2'd0: h0 <= hsel; 2'd1: h1 <= hsel; default: h2 <= hsel; endcase
          fk <= fk + 3'd1;
          if (plane == 2'd2) begin st <= DRAW; dx <= 0; end else plane <= plane + 2'd1;
        end
      end
      DRAW: begin
        if (inx && penr != 3'd7) begin
          wr_sel <= (idx >= splitq); wr_a <= oxv[8:0];
          if (penr < 3'd6) begin wr_c <= 1; wr_cd <= {1'b1, attr[3:0], penr}; end else wr_s <= 1;
        end
        if (dx == 5'd15) begin
          if (last) begin busy <= 0; st <= IDLE; end else begin idx <= idx + 6'd1; rsel <= 0; st <= R0; end
        end
        dx <= dx + 5'd1;
      end
      default: st <= IDLE;
    endcase
  end
endmodule
