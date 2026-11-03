// CPU-side RAM with an optional snapshot copy for the renderer (copied from
// the Tecmo 16 core rtl/t16_snapram.sv, commit e4ea49b; the comments below
// describe Tecmo 16's use, DEC8 uses MODE 0 and MODE 1 only).
//
// MODE 0: plain dual-port RAM. Port A is the CPU, port B the renderer reads
//         the live contents (tile RAM and palette in the default LIVE build).
// MODE 1: one snapshot. On `snap` the shadow S becomes a copy of the live RAM
//         L as it stood at that clock, and the renderer reads S (tile RAM and
//         palette in the LATCH build).
// MODE 2: two-stage snapshot for the sprite list (spec 8, tecmo16.cpp:330-341):
//         on `snap`, S2 <= S and S <= L at that clock, the renderer reads S2.
//         MAME draws frame N from the buffer as it stood at vblank N-1, which
//         holds the live RAM of vblank N-2; S is that buffer, S2 the copy the
//         line renderer reads during frame N.
//
// MAME's copy is instantaneous at the vblank callback. Here an engine walks
// the addresses, two clocks each (2,048 words: 4,096 clocks, about 43 us at
// 96 MHz). Riot and Ginkun write sprite RAM in the first 84 pixels after
// vblank starts (17 and 12 writes in 500 frames, m1_findings 3), so a plain
// sequential copy would pick up some of those writes one frame early. The
// engine is copy-before-write: a CPU write that lands while the walk is
// running is held for a few clocks, the engine first copies that address
// (unless it was already copied), then the write commits. The shadow is
// therefore exactly the RAM at the `snap` clock. A 1-bit mark per address
// records which addresses are done. DEC8 adaptation: MODE 1 accepts a new
// copy trigger while busy (Garyo issues pairs about 5.3 us apart). Restart
// the walk and clear every validity bit, so repeated triggers cannot alias
// an old epoch. A previously held CPU write commits on that restart edge;
// it belongs to the new snapshot, unlike a CPU write arriving on the edge.
// MODE 2 retains the donor's non-overlapping two-stage contract.
//
// The 68000 cannot start a second bus cycle within the hold window (a bus
// cycle is at least 32 clocks at 96 MHz), so one held write is enough;
// o_err counts any write that arrives while another is held (must stay 0).

module d8_snapram #(
    parameter int AW = 11,
    parameter int MODE = 0
) (
    input  logic          clk,
    input  logic          rst_n,
    // CPU (68000 word address, {UDS, LDS})
    input  logic [AW-1:0] i_cpu_addr,
    input  logic [15:0]   i_cpu_din,
    input  logic [1:0]    i_cpu_be,
    input  logic          i_cpu_we,
    output logic [15:0]   o_cpu_dout,
    // snapshot
    input  logic          i_snap,
    output logic          o_busy,
    output logic          o_hold,
    output logic [7:0]    o_err,
    // renderer
    input  logic [AW-1:0] i_vid_addr,
    output logic [15:0]   o_vid_q
);
  localparam int N = 1 << AW;

  generate
    if (MODE == 0) begin : g_plain
      d8_dpram #(.AW(AW), .DW(16)) u_l (
          .clk, .addr_a(i_cpu_addr), .d_a(i_cpu_din), .we_a(i_cpu_we), .be_a(i_cpu_be),
          .q_a(o_cpu_dout), .addr_b(i_vid_addr), .q_b(o_vid_q));
      assign o_busy = 1'b0;
      assign o_hold = 1'b0;
      assign o_err  = '0;
    end else begin : g_snap
      typedef enum logic [1:0] {E_ISSUE, E_DECIDE, E_COMMIT} est_t;
      est_t          st;
      logic          busy;
      logic [N-1:0]  copied;
      logic          mark_q;
      logic [AW:0]   ptr;
      logic          hold_v, svc;
      logic [AW-1:0] hold_a, ca;
      logic [15:0]   hold_d;
      logic [1:0]    hold_be;
      logic [7:0]    err;

      // address presented to the read ports this clock (ISSUE)
      logic [AW-1:0] ra;
      logic          ra_svc, ra_v;
      always_comb begin
        ra = ptr[AW-1:0];
        ra_svc = 1'b0;
        ra_v = 1'b0;
        if (busy && st == E_ISSUE) begin
          if (hold_v) begin
            ra = hold_a;
            ra_svc = 1'b1;
            ra_v = 1'b1;
          end else if (!ptr[AW]) begin
            ra_v = 1'b1;
          end
        end
      end

      // live RAM: port A = CPU, or the held write when it commits
      wire           restart = i_snap && (MODE == 1 || !busy);
      wire           commit = st == E_COMMIT || (restart && hold_v);
      wire           busy_n = busy || i_snap;
      wire           cpu_direct = i_cpu_we && !busy_n;
      logic [15:0]   l_qb, s_qb;
      d8_dpram #(.AW(AW), .DW(16)) u_l (
          .clk, .addr_a(commit ? hold_a : i_cpu_addr), .d_a(commit ? hold_d : i_cpu_din),
          .we_a(commit || cpu_direct), .be_a(commit ? hold_be : i_cpu_be),
          .q_a(o_cpu_dout), .addr_b(ra), .q_b(l_qb));

      wire dec_copy = st == E_DECIDE && !mark_q && !restart;
      /* verilator lint_off PINCONNECTEMPTY */
      always_ff @(posedge clk) begin
        if (!rst_n || restart) copied <= '0;
        else if (st == E_DECIDE) copied[ca] <= 1'b1;
        mark_q <= copied[ra];
      end
      if (MODE == 1) begin : g_one
        d8_dpram #(.AW(AW), .DW(16)) u_s (
            .clk, .addr_a(ca), .d_a(l_qb), .we_a(dec_copy), .be_a(2'b11),
            .q_a(), .addr_b(i_vid_addr), .q_b(o_vid_q));
        assign s_qb = '0;
      end else begin : g_two
        d8_dpram #(.AW(AW), .DW(16)) u_s (
            .clk, .addr_a(ca), .d_a(l_qb), .we_a(dec_copy), .be_a(2'b11),
            .q_a(), .addr_b(ra), .q_b(s_qb));
        d8_dpram #(.AW(AW), .DW(16)) u_s2 (
            .clk, .addr_a(ca), .d_a(s_qb), .we_a(dec_copy), .be_a(2'b11),
            .q_a(), .addr_b(i_vid_addr), .q_b(o_vid_q));
      end
      /* verilator lint_on PINCONNECTEMPTY */

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          st <= E_ISSUE;
          busy <= 1'b0;
          ptr <= '0;
          hold_v <= 1'b0;
          svc <= 1'b0;
          err <= '0;
        end else begin
          if (restart) begin
            busy <= 1'b1;
            ptr <= '0;
            st <= E_ISSUE;
            svc <= 1'b0;
          end else if (i_snap && busy && err != 8'hFF) begin
            err <= err + 8'd1;      // a snapshot request during a snapshot is dropped
          end
          if (i_cpu_we && busy_n) begin
            if (hold_v && !commit && err != 8'hFF) err <= err + 8'd1;
            hold_v <= 1'b1;
            hold_a <= i_cpu_addr;
            hold_d <= i_cpu_din;
            hold_be <= i_cpu_be;
          end else if (commit) hold_v <= 1'b0;
          if (busy && !restart) begin
            case (st)
              E_ISSUE: begin
                if (ra_v) begin
                  ca <= ra;
                  svc <= ra_svc;
                  st <= E_DECIDE;
                end else if (!hold_v && !i_cpu_we) begin
                  busy <= 1'b0;   // a write arriving now is held and serviced first
                end
              end
              E_DECIDE: begin
                if (svc) st <= E_COMMIT;
                else begin
                  ptr <= ptr + 1'b1;
                  st <= E_ISSUE;
                end
              end
              E_COMMIT: begin
                if (!(i_cpu_we && busy_n)) hold_v <= 1'b0;
                svc <= 1'b0;
                st <= E_ISSUE;
              end
              default: st <= E_ISSUE;
            endcase
          end
        end
      end
      assign o_busy = busy;
      assign o_hold = hold_v;
      assign o_err  = err;
    end
  endgenerate

endmodule
