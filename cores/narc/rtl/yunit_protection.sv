// -----------------------------------------------------------------------------
// yunit_protection.sv
//
// The Midway Y-Unit "special chip" protection, per MAME williams/midyunit_m.cpp
// (cmos_enable_w + protection_r). Games clock a fixed data sequence out of the
// chip by writing a reset pattern then toggling bit 0x0800; a read returns the
// most-recently-clocked value. Smash TV has no protection chip (game_id 0):
// this module then returns 0, matching MAME m_prot_data = nullptr.
//
// Write (cmos_enable_w), value masked to 0x0f00, into a 3-deep FIFO:
//   after shift, if FIFO == reset_sequence -> prot_index = 0
//   on a falling edge of bit 0x0800 between FIFO[1] and the new entry ->
//     prot_result = data_sequence[prot_index++]
//
// Per-game reset/data tables are transcribed verbatim from init_trog /
// init_hiimpact / init_shimpact. Strike Force's 0x1234 RAM-read variant is a
// different mechanism and is intentionally NOT handled here (its game_id keeps
// prot_result = 0 until implemented).
// -----------------------------------------------------------------------------

`default_nettype none
module yunit_protection (
  input  wire        clk,
  input  wire        rst,
  input  wire [7:0]  game_id,   // 1=trog 2=hiimpact 3=shimpact
  input  wire        we,        // write strobe to 0x01C00060-7F (cmos_enable_w)
  input  wire [15:0] wdata,
  output reg  [15:0] result
);
  reg [15:0] seq1, seq2;         // retained FIFO entries, masked to 0x0f00
  reg [3:0]  idx;

  // --- per-game reset sequence (3 values) ---
  reg [15:0] rst0, rst1, rst2;
  always_comb begin
    case (game_id)
      8'd1:    begin rst0=16'h0f00; rst1=16'h0f00; rst2=16'h0f00; end // trog
      8'd2:    begin rst0=16'h0b00; rst1=16'h0b00; rst2=16'h0b00; end // hiimpact
      8'd3:    begin rst0=16'h0f00; rst1=16'h0e00; rst2=16'h0d00; end // shimpact
      default: begin rst0=16'hffff; rst1=16'hffff; rst2=16'hffff; end // never matches
    endcase
  end

  // --- per-game data sequence (15 entries) ---
  reg [15:0] data_val;
  always_comb begin
    case (game_id)
      8'd1: begin // trog
        case (idx)
          4'd0:  data_val=16'h3000; 4'd1:  data_val=16'h1000; 4'd2:  data_val=16'h2000;
          4'd3:  data_val=16'h0000; 4'd4:  data_val=16'h2000; 4'd5:  data_val=16'h3000;
          4'd6:  data_val=16'h3000; 4'd7:  data_val=16'h1000; 4'd8:  data_val=16'h0000;
          4'd9:  data_val=16'h0000; 4'd10: data_val=16'h2000; 4'd11: data_val=16'h3000;
          4'd12: data_val=16'h1000; 4'd13: data_val=16'h1000; 4'd14: data_val=16'h2000;
          default: data_val=16'h0000;
        endcase
      end
      8'd2: begin // hiimpact
        case (idx)
          4'd0:  data_val=16'h2000; 4'd1:  data_val=16'h4000; 4'd2:  data_val=16'h4000;
          4'd3:  data_val=16'h0000; 4'd4:  data_val=16'h6000; 4'd5:  data_val=16'h6000;
          4'd6:  data_val=16'h2000; 4'd7:  data_val=16'h4000; 4'd8:  data_val=16'h2000;
          4'd9:  data_val=16'h4000; 4'd10: data_val=16'h2000; 4'd11: data_val=16'h0000;
          4'd12: data_val=16'h4000; 4'd13: data_val=16'h6000; 4'd14: data_val=16'h2000;
          default: data_val=16'h0000;
        endcase
      end
      8'd3: begin // shimpact
        case (idx)
          4'd0:  data_val=16'h0000; 4'd1:  data_val=16'h4000; 4'd2:  data_val=16'h2000;
          4'd3:  data_val=16'h5000; 4'd4:  data_val=16'h2000; 4'd5:  data_val=16'h1000;
          4'd6:  data_val=16'h4000; 4'd7:  data_val=16'h6000; 4'd8:  data_val=16'h3000;
          4'd9:  data_val=16'h0000; 4'd10: data_val=16'h2000; 4'd11: data_val=16'h5000;
          4'd12: data_val=16'h5000; 4'd13: data_val=16'h5000; 4'd14: data_val=16'h2000;
          default: data_val=16'h0000;
        endcase
      end
      default: data_val = 16'h0000;
    endcase
  end

  wire [15:0] masked = wdata & 16'h0f00;
  // post-shift FIFO = [seq1, seq2, masked]; compare to reset_sequence[0..2]
  wire reset_match = (seq1 == rst0) && (seq2 == rst1) && (masked == rst2);
  // falling edge of bit 0x0800 between FIFO[1](=seq2) and new entry(=masked)
  wire clock_edge  = seq2[11] && ~masked[11];

  always_ff @(posedge clk) begin
    if (rst) begin
      seq1 <= 16'h0; seq2 <= 16'h0; idx <= 4'h0; result <= 16'h0;
    end else if (we) begin
      seq1 <= seq2;  seq2 <= masked;                  // shift FIFO
      if (reset_match)     idx <= 4'h0;
      else if (clock_edge) begin
        result <= data_val;
        idx    <= idx + 4'h1;
      end
    end
  end
endmodule
`default_nettype wire
