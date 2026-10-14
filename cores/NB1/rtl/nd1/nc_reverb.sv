//------------------------------------------------------------------------------
// Cabinet reverb: a short, dark room around the whole mix. An option, not the
// board. The Pole Position core's pp_reverb (itself the Punch-Out!! core's
// po_reverb made stereo), unchanged in its sound:
//
// three parallel feedback comb filters at 29.7, 37.1 and 41.1 ms (mutually
// prime lengths, so their tails do not line up into a ring), each with a
// one-pole low-pass in its loop so the tail darkens as it decays, feedback 5/8
// (about 0.4 s to -60 dB, or 13/16 and about 1.2 s for Heavy); their sum is
// added under the dry signal at 3/16 (Light, Heavy) or 1/4 (Medium). The combs
// are fed the mid signal, (L + R) / 2, and the one wet tail goes under both
// channels: the C352's stereo image is kept, and the room is the same on both
// sides as a cabinet's is.
//
// One sample per ce, which must be 48 kHz for those lengths (the C352 runs at
// 85.3 kHz; target/pocket/core_top.sv makes the 48 kHz stream). The work is
// sequential and takes about ten clocks. Delay lines in block RAM,
// 3 x 2048 x 16. All arithmetic is shifts and adds; every sum is saturated.
// Mode 0 passes the input through with the same one-sample latency as the
// other modes.
//------------------------------------------------------------------------------
`default_nettype none

module nc_reverb (
    input  wire               clk,
    input  wire               reset,
    input  wire               ce,          // one 48 kHz tick; in_l/in_r valid with it
    input  wire        [1:0]  mode,        // 0 off, 1 light, 2 medium, 3 heavy
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output logic signed [15:0] out_l,      // valid until the next ce, a few clocks after this one
    output logic signed [15:0] out_r
);
    localparam [10:0] D0 = 11'd1426, D1 = 11'd1781, D2 = 11'd1973;

    logic [10:0] wp;                       // write pointer, common to the three lines
    logic [10:0] ra;
    logic        we;
    logic signed [15:0] wd0, wd1, wd2;
    wire  signed [15:0] q0, q1, q2;
    nc_sdpram #(.AW(11), .DW(16)) u_l0 (.clk(clk), .wa(wp), .we(we), .d(wd0), .ra(ra), .q(q0));
    nc_sdpram #(.AW(11), .DW(16)) u_l1 (.clk(clk), .wa(wp), .we(we), .d(wd1), .ra(ra), .q(q1));
    nc_sdpram #(.AW(11), .DW(16)) u_l2 (.clk(clk), .wa(wp), .we(we), .d(wd2), .ra(ra), .q(q2));

    logic signed [15:0] lp0 /* verilator public_flat_rd */, lp1, lp2;
    logic signed [15:0] xl, xr, xm;        // the dry pair and the mid being processed
    logic signed [17:0] wet;
    logic signed [15:0] r0, r1, r2;

    // Every extension goes through a declared-signed variable first: a bare
    // concatenation is unsigned in SystemVerilog and would turn the
    // arithmetic shifts below into logical ones (po_reverb's first version
    // pinned its damping states at +32767 that way).
    function automatic logic signed [15:0] sat18(input logic signed [17:0] v);
        sat18 = (v > 18'sd32767) ? 16'sd32767 : (v < -18'sd32768) ? -16'sd32768 : v[15:0];
    endfunction
    function automatic logic signed [17:0] ext18(input logic signed [15:0] v);
        ext18 = 18'(v);                     // sign-extended, signed to signed
    endfunction
    // y += (r - y) / 4, the loop's damping
    function automatic logic signed [15:0] damp(input logic signed [15:0] y, input logic signed [15:0] r);
        logic signed [17:0] d, ys, q;
        ys = ext18(y); d = ext18(r) - ys; q = d >>> 2;
        damp = sat18(ys + q);
    endfunction
    // x + lp * g, what goes back into the line: g = 5/8, or 13/16 for the long tail
    function automatic logic signed [15:0] fb(input logic signed [15:0] xin, input logic signed [15:0] lp, input logic long_tail);
        logic signed [17:0] l, s;
        l = ext18(lp);
        s = long_tail ? ext18(xin) + (l >>> 1) + (l >>> 2) + (l >>> 4)
                      : ext18(xin) + (l >>> 1) + (l >>> 3);
        fb = sat18(s);
    endfunction
    // dry + wet at 3/16 (light; heavy, whose combs ring louder), or 1/4 (medium)
    function automatic logic signed [15:0] mix(input logic signed [15:0] xin, input logic signed [17:0] w, input logic quarter);
        logic signed [17:0] s;
        s = quarter ? ext18(xin) + (w >>> 2) : ext18(xin) + (w >>> 3) + (w >>> 4);
        mix = sat18(s);
    endfunction
    // (l + r) / 2, arithmetic
    function automatic logic signed [15:0] mid(input logic signed [15:0] l, input logic signed [15:0] r);
        logic signed [17:0] s;
        s = ext18(l) + ext18(r);
        mid = sat18(s >>> 1);
    endfunction

    typedef enum logic [3:0] { S_IDLE, S_A0, S_A1, S_A2, S_R0, S_R1, S_R2, S_MIX, S_WR } st_t;
    st_t st;

    always_ff @(posedge clk) begin
        we <= 1'b0;
        if (reset) begin
            st <= S_IDLE; wp <= '0; ra <= '0;
            lp0 <= '0; lp1 <= '0; lp2 <= '0;
            out_l <= '0; out_r <= '0; xl <= '0; xr <= '0; xm <= '0; wet <= '0;
        end else begin
            case (st)
                S_IDLE: if (ce) begin
                    xl <= in_l; xr <= in_r; xm <= mid(in_l, in_r);
                    ra <= wp - D0; st <= S_A0;
                end
                // each read: the address is set one state before, q is valid
                // two clocks after the address is set
                S_A0: begin ra <= wp - D1; st <= S_A1; end
                S_A1: begin r0 <= q0; ra <= wp - D2; st <= S_A2; end       // q0 = line0[wp-D0]
                S_A2: begin r1 <= q1; st <= S_R2; end                      // q1 = line1[wp-D1]
                S_R2: begin r2 <= q2; st <= S_R0; end                      // q2 = line2[wp-D2]
                S_R0: begin
                    lp0 <= damp(lp0, r0); lp1 <= damp(lp1, r1); lp2 <= damp(lp2, r2);
                    st <= S_R1;
                end
                S_R1: begin
                    wet <= ext18(lp0) + ext18(lp1) + ext18(lp2);
                    wd0 <= fb(xm, lp0, mode == 2'd3);
                    wd1 <= fb(xm, lp1, mode == 2'd3);
                    wd2 <= fb(xm, lp2, mode == 2'd3);
                    st <= S_MIX;
                end
                S_MIX: begin
                    case (mode)
                        2'd0:    begin out_l <= xl; out_r <= xr; end
                        2'd2:    begin out_l <= mix(xl, wet, 1'b1); out_r <= mix(xr, wet, 1'b1); end
                        default: begin out_l <= mix(xl, wet, 1'b0); out_r <= mix(xr, wet, 1'b0); end
                    endcase
                    we <= 1'b1;
                    st <= S_WR;
                end
                S_WR: begin wp <= wp + 11'd1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule

// simple dual-port RAM, registered read (the delay lines)
module nc_sdpram #(parameter AW = 8, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] wa,
    input  wire           we,
    input  wire  [DW-1:0] d,
    input  wire  [AW-1:0] ra,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:(1 << AW)-1];
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

`default_nettype wire
