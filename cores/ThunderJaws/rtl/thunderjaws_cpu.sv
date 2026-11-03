// SPDX-License-Identifier: GPL-3.0-or-later
// ThunderJaws fx68k wrapper, adapted from the Skull & Crossbones wrapper in
// donors/cpu/reference/skullxbo_cpu.sv (MiSTer-devel commit
// 73fdc2408c69ee6db26394ce1d346745d440cf0c). See donors/cpu/NOTICE.md.
// The donor's board-specific phase, wait, and interrupt behavior is not used.

module thunderjaws_cpu #(parameter integer EXTERNAL_PHASE = 0) (
    input  logic        clk_sys,
    input  logic        reset,       // Synchronous active-high CPU reset
    input  logic        phase_phi1,   // Used only when EXTERNAL_PHASE is set
    input  logic        phase_phi2,
    input  logic  [2:0] ipl_n,       // Active low; 3'b111 means no interrupt

    output logic [23:0] address,     // Aligned byte address
    output logic [15:0] data_out,
    input  logic [15:0] data_in,
    output logic        as,          // Active-high copy of /AS
    output logic        uds_n,
    output logic        lds_n,
    output logic        rw,          // 1 = read, 0 = write
    output logic  [2:0] fc,
    input  logic        dtack_n,     // External active-low response, held through sampling
    input  logic        vpa_n        // External active-low autovector response
);

    logic       en_phi1;
    logic       en_phi2;
    logic [2:0] ipl_meta;
    logic [2:0] ipl_sync;

    // The CPU advances only on enables; clk_sys remains the sole clock.
    // A pair can provide one reset-independent phase schedule to both CPUs.
    generate
        if (EXTERNAL_PHASE != 0) begin : g_external_phase
            // Do not gate these enables with the logical CPU reset. The kernel
            // is reset separately, while the pair's shared phase keeps running.
            assign en_phi1 = phase_phi1;
            assign en_phi2 = phase_phi2;
        end else begin : g_internal_phase
            logic [2:0] phase_count;

            // Standalone compatibility profile: Phi1 every six fabric clocks,
            // Phi2 three clocks later, with a reset-relative phase origin.
            always_ff @(posedge clk_sys) begin
                if (reset)
                    phase_count <= 3'd0;
                else
                    phase_count <= (phase_count == 3'd5) ? 3'd0 : phase_count + 3'd1;
            end

            assign en_phi1 = !reset && (phase_count == 3'd0);
            assign en_phi2 = !reset && (phase_count == 3'd3);
        end
    endgenerate

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            ipl_meta <= 3'b111;
            ipl_sync <= 3'b111;
        end else begin
            ipl_meta <= ipl_n;
            ipl_sync <= ipl_meta;
        end
    end

    wire        fx_as_n;
    wire        fx_reset_n;
    wire [23:1] fx_eab;
    wire        fx_e;
    wire        fx_vma_n;
    wire        fx_bg_n;
    wire        fx_halted_n;

    assign address = {fx_eab, 1'b0};
    assign as = ~fx_as_n;

    fx68k u_fx68k (
        .clk      (clk_sys),
        .HALTn    (1'b1),
        .extReset (reset),
        .pwrUp    (reset),
        .enPhi1   (en_phi1),
        .enPhi2   (en_phi2),

        .eRWn     (rw),
        .ASn      (fx_as_n),
        .LDSn     (lds_n),
        .UDSn     (uds_n),
        .E        (fx_e),
        .VMAn     (fx_vma_n),

        .FC0      (fc[0]),
        .FC1      (fc[1]),
        .FC2      (fc[2]),
        .BGn      (fx_bg_n),
        .oRESETn  (fx_reset_n),
        .oHALTEDn (fx_halted_n),

        .DTACKn   (dtack_n),
        .VPAn     (vpa_n),
        .BERRn    (1'b1),
        .BRn      (1'b1),
        .BGACKn   (1'b1),
        .IPL0n    (ipl_sync[0]),
        .IPL1n    (ipl_sync[1]),
        .IPL2n    (ipl_sync[2]),

        .iEdb     (data_in),
        .oEdb     (data_out),
        .eab      (fx_eab)
    );

endmodule
