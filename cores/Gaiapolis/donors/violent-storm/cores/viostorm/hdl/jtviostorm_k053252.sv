// Violent Storm K053252/CCU integration.
//
// The counter and blank/sync equations are imported from the GPL-licensed
// JTCORES Run-and-Gun donor at pinned JTCORES commit
// c990f843c7bd8eaf26179a0632bac1436cc05b52. The wrapper owns the GX board's
// low-byte 68000 contract and the title-specific reset image; it is not a
// claim that the donor defaults are silicon evidence.
//
// Both games program the CCU with even-address byte writes, which the
// low-byte lane never receives (as in MAME). Each board therefore needs its
// own reset image. Monster Maulers uses the values its program writes
// (MAME 0.289 trace: 384x264 total at 6 MHz, 288x224 active, H=200..487,
// V=272..495), matching MAME's 59.19 Hz raster and the renderer origins.
module jtviostorm_k053252(
    input  logic        rst,
    input  logic        clk,
    input  logic        cen,
    input  logic        monster,
    input  logic        cs,
    input  logic        rnw,
    input  logic [3:0]  addr,
    input  logic [1:0]  dsn,
    input  logic [15:0] din,
    output logic [7:0]  dout,
    output logic        lhbl,
    output logic        lvbl,
    output logic        hs,
    output logic        vs,
    output logic        int1,
    output logic        int2,
    output logic [8:0]  hpos,
    output logic [8:0]  vpos
);
    // MAME's umask16(0x00ff) means only the low byte reaches the CCU.
    wire low_byte_cs = cs && !dsn[0];
    // The generated MMR loads INIT[i*8 +: 8], so these literals are the
    // reverse of the documented register table (reg0..reg15).
    // Local Gaiapolis footage calibration: 506x264 at 8 MHz. Shorten the
    // horizontal total and back porch by six pixels together, preserving
    // the active H=106..490 coordinates used by the renderers. This is a
    // measured playback-rate calibration, not a PCB register dump.
    // Evidence and original image: docs/PCB_SPEED_CALIBRATION.md.
    localparam [127:0] INIT_GAIAPOLIS = 128'h00_00_00_75_0E_11_07_01_00_00_33_00_16_00_F9_01;
    localparam [127:0] INIT_MONSTER   = 128'h00_00_00_73_0F_10_07_01_00_00_27_00_19_00_7F_01;

    logic [7:0] ccu_dout [0:1];
    logic [1:0] ccu_lhbl, ccu_lvbl, ccu_hs, ccu_vs, ccu_int1, ccu_int2;
    logic [8:0] ccu_hpos [0:1], ccu_vpos [0:1];

    genvar k;
    generate for (k=0; k<2; k=k+1) begin : g_ccu
        jtk053252 #(.INIT(k==0 ? INIT_GAIAPOLIS : INIT_MONSTER)) u_ccu (
            .rst        ( rst              ),
            .clk        ( clk              ),
            .pxl_cen    ( cen              ),
            .sel        ( 3'd0             ),
            .vldi       ( 1'b1             ),
            .hldi       ( 1'b1             ),
            .cs         ( low_byte_cs      ),
            .addr       ( addr             ),
            .rnw        ( rnw              ),
            .din        ( din[7:0]         ),
            .dout       ( ccu_dout[k]      ),
            .lhbl       ( ccu_lhbl[k]      ),
            .lvbl       ( ccu_lvbl[k]      ),
            .hs         ( ccu_hs[k]        ),
            .vs         ( ccu_vs[k]        ),
            .int1       ( ccu_int1[k]      ),
            .int2       ( ccu_int2[k]      ),
            .hpos       ( ccu_hpos[k]      ),
            .vpos       ( ccu_vpos[k]      ),
            .hld        (                  ),
            .vld        (                  ),
            .lhbs       (                  ),
            .ioctl_addr ( 4'd0             ),
            .ioctl_din  (                  )
        );
    end endgenerate

    assign dout = ccu_dout[monster];
    assign lhbl = ccu_lhbl[monster];
    assign lvbl = ccu_lvbl[monster];
    assign hs   = ccu_hs[monster];
    assign vs   = ccu_vs[monster];
    assign int1 = ccu_int1[monster];
    assign int2 = ccu_int2[monster];
    assign hpos = ccu_hpos[monster];
    assign vpos = ccu_vpos[monster];
endmodule
