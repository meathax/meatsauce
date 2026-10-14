// Violent Storm K053252/CCU integration.
//
// The counter and blank/sync equations are imported from the GPL-licensed
// JTCORES Run-and-Gun donor at pinned JTCORES commit
// c990f843c7bd8eaf26179a0632bac1436cc05b52. The wrapper owns the GX board's
// low-byte 68000 contract and the title-specific reset image; it is not a
// claim that the donor defaults are silicon evidence.
module jtviostorm_k053252(
    input  logic        rst,
    input  logic        clk,
    input  logic        cen,
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

    jtk053252 #(
        // The generated MMR loads INIT[i*8 +: 8], so this literal is the
        // reverse of the documented register table (reg0..reg15).
        .INIT(128'h00_00_00_75_0E_11_07_01_00_00_39_00_16_00_FF_01)
    ) u_ccu (
        .rst        ( rst         ),
        .clk        ( clk         ),
        .pxl_cen    ( cen         ),
        .sel        ( 3'd0        ),
        .vldi       ( 1'b1        ),
        .hldi       ( 1'b1        ),
        .cs         ( low_byte_cs ),
        .addr       ( addr        ),
        .rnw        ( rnw         ),
        .din        ( din[7:0]    ),
        .dout       ( dout        ),
        .lhbl       ( lhbl        ),
        .lvbl       ( lvbl        ),
        .hs         ( hs          ),
        .vs         ( vs          ),
        .int1       ( int1        ),
        .int2       ( int2        ),
        .hpos       ( hpos        ),
        .vpos       ( vpos        ),
        .hld        (              ),
        .vld        (              ),
        .lhbs       (              ),
        .ioctl_addr ( 4'd0        ),
        .ioctl_din  (              )
    );
endmodule
