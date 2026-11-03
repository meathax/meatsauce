/*============================================================================
  Dongle Type 3 — 12-bit counter + latch + bit-swap PROM

  Implements the Type 3 dongle used in games like Burger Time (cbtime),
  Cluster Buster, Graphics Peel, etc.

  The dongle performs:
  1. A 12-bit counter (m_type3_ctrs) that increments on certain CPU read cycles
  2. Latching of 8041 D0 status bit (m_type3_d0_latch)
  3. Latching of PAL pin-19 (m_type3_pal_19) to enable/disable PROM reads
  4. PROM lookup (256 bytes, indexed by counter bits 7:0)
  5. Configurable bit-swap on the returned PROM byte (11 swap modes per game)

  Reference: decocass_m.cpp lines 622–851

  State variables (from decocass.h):
    - m_type3_ctrs    : 12-bit counter
    - m_type3_d0_latch: Latched 8041-D0 bit (affects output bit 0)
    - m_type3_pal_19  : Latched PAL pin-19 (gates PROM vs. 8041 status)
    - m_type3_swap    : Swap mode (0–10 for TYPE3_SWAP_**)

  Counter behavior (decocass_m.cpp line 633):
    - Increments on cpu_re when offset & 1 == 1 and m_type3_pal_19 == 1
    - Wraps to 0 at 4096

  PAL pin-19 behavior:
    - When pal_19 == 1: PROM is active, return PROM[counter]
    - When pal_19 == 0: 8041 status is routed (with bit-swap)
    - Activated by writing 0xC0–0xCF to E5x1 (lines 837–838)

  Swap modes (TYPE3_SWAP_* enum, decocass_m.cpp lines 39–51):
    0: TYPE3_SWAP_01   — swap bits 0 (d0_latch) and 1 (save[1])
    1: TYPE3_SWAP_12   — swap bits 1 (save[2]) and 2 (save[1])
    2: TYPE3_SWAP_13   — swap bits 1 (save[3]), 2 (save[2]), 3 (save[1])
    3: TYPE3_SWAP_24   — complex swap involving bits 2,4,3
    4: TYPE3_SWAP_25   — complex swap involving bits 2,5,4
    5: TYPE3_SWAP_34_0 — swap bits 3 and 4, d0_latch at [0]
    6: TYPE3_SWAP_34_7 — swap bits 3 and 4, d0_latch at [7], save[7] at [0]
    7: TYPE3_SWAP_45   — swap bits 4 and 5
    8: TYPE3_SWAP_23_56— multiple swaps: 2↔3, 5↔6
    9: TYPE3_SWAP_56   — swap bits 5 and 6
   10: TYPE3_SWAP_67   — swap bits 6 and 7

  Burger Time (cbtime) uses TYPE3_SWAP_12 (mode 1) — decocass_m.cpp line 1590.
============================================================================*/

`timescale 1 ps / 1 ps

module dongle_type3 (
    input  wire        clk_sys,
    input  wire        ce_hclk4,
    input  wire        reset,

    input  wire        cpu_re,
    input  wire        cpu_we,
    input  wire [7:0]  cpu_addr_lo,
    input  wire [7:0]  cpu_dout,
    output reg  [7:0]  cpu_din_full,        // 2026-05-18: 8-bit per MAME

    input  wire [3:0]  swap_mode,
    input  wire        mcu_status_d0,
    input  wire [7:0]  mcu_dbb_dout,
    input  wire [7:0]  mcu_dbb_sts,

    output reg  [11:0] prom_addr,
    input  wire [7:0]  prom_q
);

    //------------------------------------------------------------------------
    // Internal state (synchronous updates)
    //------------------------------------------------------------------------
    reg [11:0] m_type3_ctrs;      // 12-bit counter (0–4095)
    reg        m_type3_d0_latch;  // Latched 8041 D0 bit
    reg        m_type3_pal_19;    // PAL pin-19 latch (gates PROM vs. 8041)

    //------------------------------------------------------------------------
    // Synchronous state updates
    //------------------------------------------------------------------------
    always @(posedge clk_sys) begin
        if (reset) begin
            m_type3_ctrs      <= 12'h000;
            m_type3_d0_latch  <= 1'b0;
            m_type3_pal_19    <= 1'b0;
        end
        else if (ce_hclk4) begin
            // Write handler: cpu_we and cpu_addr_lo[0] == 1
            // (decocass_m.cpp lines 827–851)
            if (cpu_we) begin
                if (cpu_addr_lo[0] == 1'b1) begin  // Write to odd address (E5x1)
                    if (m_type3_pal_19 == 1'b1) begin
                        // Load counter with cpu_dout << 4 (line 832)
                        m_type3_ctrs <= {cpu_dout[7:0], 4'h0};
                    end
                    else if ((cpu_dout[7:4] == 4'hC)) begin
                        // Activate PAL pin-19 when data & 0xF0 == 0xC0 (lines 837–838)
                        m_type3_pal_19 <= 1'b1;
                    end
                end
            end

            // Read handler: cpu_re and cpu_addr_lo[0] == 1
            // (decocass_m.cpp lines 626–634)
            if (cpu_re) begin
                if (cpu_addr_lo[0] == 1'b1) begin  // Read from odd address (E5x1)
                    if (m_type3_pal_19 == 1'b1) begin
                        // PROM mode: increment counter after read (line 633)
                        if (m_type3_ctrs == 12'hFFF) begin
                            m_type3_ctrs <= 12'h000;  // Wrap at 4096
                        end
                        else begin
                            m_type3_ctrs <= m_type3_ctrs + 12'h001;
                        end
                    end
                end
                else begin  // Read from even address (E5x0)
                    // FIX 2026-05-30: MAME line 798 latches `save & 1` = the 8041 DATA byte's bit 0
                    // (DBBOUT[0]), and only in the pal_19==0 path. Was mcu_status_d0 (wrong bit/source).
                    if (m_type3_pal_19 == 1'b0)
                        m_type3_d0_latch <= mcu_dbb_dout[0];
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // PROM address generation: full 12-bit counter when pal_19 is active
    // (decocass_m.cpp line 630: `data = m_donglerom[m_type3_ctrs];`)
    // Counter wraps at 4096 — full 4 KB PROM is addressable.
    //------------------------------------------------------------------------
    always @(*) begin
        prom_addr = m_type3_ctrs;
    end

    //------------------------------------------------------------------------
    // Output data mux: PROM vs. 8041 status with bit-swap
    //------------------------------------------------------------------------
    always @(*) begin
        reg [7:0] prom_data;
        reg [7:0] data_out;

        // PROM data or 8041 status
        if (m_type3_pal_19 == 1'b1) begin
            // PROM mode: return PROM output directly (odd address)
            prom_data = prom_q;
            // NOTE: For even address reads in PROM mode, return 0xFF (open bus)
            //       This is handled at line 654 in MAME and returns 0xFF.
            //       For now, we assume cpu_din_low4 is always from the odd address path.
            data_out = prom_q;
        end
        else begin
            // 8041 status mode: apply bit-swap transformation
            // Bit 0 is always D0 latch in most modes (except SWAP_34_7)
            // FIX 2026-05-30: MAME swaps `save = upi41_master_r(0)` = the 8041 DATA byte (DBBOUT),
            // NOT prom_q. The swap source must be mcu_dbb_dout. (Was prom_q → whole byte wrong.)
            prom_data = mcu_dbb_dout;

            // Decode the swap mode and apply bit permutation
            // (decocass_m.cpp lines 662–795)
            case (swap_mode[3:0])
                4'd0: begin  // TYPE3_SWAP_01 (mode 0)
                    // Swap bits 0 (d0_latch) and 1 (prom_data[1])
                    data_out[0] = prom_data[1];
                    data_out[1] = m_type3_d0_latch;
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd1: begin  // TYPE3_SWAP_12 (mode 1) — Burger Time (cbtime)
                    // d0_latch at [0], swap bits [2] and [1] from prom
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[2];
                    data_out[2] = prom_data[1];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd2: begin  // TYPE3_SWAP_13 (mode 2)
                    // d0_latch at [0], complex shuffle of bits [3,2,1]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[3];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[1];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd3: begin  // TYPE3_SWAP_24 (mode 3)
                    // d0_latch at [0], swap bits [4,3] with [2,4]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[4];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[2];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd4: begin  // TYPE3_SWAP_25 (mode 4)
                    // d0_latch at [0], swap bits [5,4,2]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[5];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[2];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd5: begin  // TYPE3_SWAP_34_0 (mode 5)
                    // d0_latch at [0], swap bits [3] and [4]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[4];
                    data_out[4] = prom_data[3];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd6: begin  // TYPE3_SWAP_34_7 (mode 6)
                    // prom_data[7] at [0], swap bits [3] and [4], d0_latch at [7]
                    data_out[0] = prom_data[7];
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[4];
                    data_out[4] = prom_data[3];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = m_type3_d0_latch;
                end

                4'd7: begin  // TYPE3_SWAP_45 (mode 7)
                    // d0_latch at [0], swap bits [4] and [5]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[5];
                    data_out[5] = prom_data[4];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end

                4'd8: begin  // TYPE3_SWAP_23_56 (mode 8)
                    // d0_latch at [0], swap bits [2,3] and [5,6]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[3];
                    data_out[3] = prom_data[2];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[6];
                    data_out[6] = prom_data[5];
                    data_out[7] = prom_data[7];
                end

                4'd9: begin  // TYPE3_SWAP_56 (mode 9)
                    // d0_latch at [0], swap bits [5] and [6]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[6];
                    data_out[6] = prom_data[5];
                    data_out[7] = prom_data[7];
                end

                4'd10: begin  // TYPE3_SWAP_67 (mode 10)
                    // d0_latch at [0], swap bits [6] and [7]
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[7];
                    data_out[7] = prom_data[6];
                end

                default: begin  // Invalid mode or mode 0
                    data_out[0] = m_type3_d0_latch;
                    data_out[1] = prom_data[1];
                    data_out[2] = prom_data[2];
                    data_out[3] = prom_data[3];
                    data_out[4] = prom_data[4];
                    data_out[5] = prom_data[5];
                    data_out[6] = prom_data[6];
                    data_out[7] = prom_data[7];
                end
            endcase
        end

        // 2026-05-18 — 8-bit per MAME decocass_type3_r. Status path returns
        // DBBSTS, data path returns the swapped/PROM byte computed above.
        // Output mux — MAME decocass_type3_r (dispatcher already gated offset&2==0):
        //   A0==1: pal_19 ? PROM[ctrs] : 8041-STATUS        A0==0: pal_19 ? open-bus(0xFF) : SWAP(DBBOUT)
        if (cpu_addr_lo[0] == 1'b1) begin
            cpu_din_full = m_type3_pal_19 ? data_out : mcu_dbb_sts;   // data_out==prom_q when pal_19
        end else begin
            // FIX 2026-05-30: A0==0 → 0xFF (open bus) under pal_19, else the SWAPPED DBBOUT byte
            // (was pal_19?prom_q:raw-DBBOUT — both wrong).
            cpu_din_full = m_type3_pal_19 ? 8'hFF : data_out;
        end
    end

endmodule
