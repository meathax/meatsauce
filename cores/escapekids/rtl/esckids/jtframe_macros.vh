// JTFRAME configuration for the Escape Kids MiSTer target.
// Keep these definitions in one project-owned file so Verilator, Quartus and
// source-manifest generation use the same effective build contract.
`ifndef ESCAPE_KIDS_JTFRAME_MACROS
`define ESCAPE_KIDS_JTFRAME_MACROS

`define CORENAME EscapeKids
`define GAMETOP jtsimson_game_sdram
`define JTFRAME_MEMGEN
`define JTFRAME_HEADER 4
`define JTFRAME_CLK48
`define JTFRAME_MR_DDRLOAD
`define JTFRAME_STEREO
`define JTFRAME_COLORW 8
`define JTFRAME_PXLCLK 6
`define JTFRAME_WIDTH 320
`define JTFRAME_HEIGHT 240
`define JTFRAME_BUTTONS 3
// Escape's MRA uses the two slots after Start/Coin for Service and Test.
// JTFRAME's generic decoder reserves the first of those slots for pause;
// route this profile through its actual service/test inputs instead.
`define JTFRAME_ESCKIDS_SERVICE_TEST
`define JTFRAME_JOY_DURL
`define JTFRAME_JOY1_POS
`define JTFRAME_RATE 59.19
`define JTFRAME_BA1_START 26'h080000
// Bank 0 is serviced by the MiSTer SDRAM wrapper as a 32-bit burst.
// Propagate that physical burst width into the generated ROM slot so its
// two-beat cache captures the same line phase as the board controller.
`define JTFRAME_BA0_LEN 32
`define PCM_START 26'h0A0000
`define JTFRAME_BA2_START 26'h1E0000
// Bank 2 reads one 32-bit tile row per transaction (JTFRAME's default: no
// JTFRAME_BA2_LEN, so BA2_LEN=32 and the mode register uses a 2-word burst).
//
// A previous revision set JTFRAME_BA2_LEN 64 to "fetch two vertically
// adjacent tile rows per transaction". The second row is never reused: it is
// the same tile's next scanline, and the two-entry romrq cache is overwritten
// by the following 40 tiles long before that line is drawn. So the extra two
// beats were pure DQ occupancy, and they cost far more than they saved.
// Measured on the pin-level bank-2 bench (.mister/tb/tb_ba2_read.sv, chip
// model in the loop, three layers plus CPU/PCM contention, 6000 fetch groups
// each): 64-bit reads gave mean 19.0 clk48 but a max of 297 and 11 groups
// (0.18%) past 64 clk48; 32-bit reads gave mean 22.0, max 23, and nothing
// above 40. The K051962 latches each layer word on a fixed pixel deadline
// with no valid signal (jt051962 has no lyrX_ok input at all), so every group
// in that tail is an 8-pixel run of the previous fetch's data - the 8x1
// strips on the scrolling background, at a rate matching the 0.18% tail.
// The K051962 latches each layer word on a fixed pixel deadline with no
// handshake, so bank 2 must win SDRAM arbitration ahead of the CPU (bank 0)
// and PCM (bank 1) requests, which both tolerate waits.  Without this, a
// bank-0/bank-1 grant between the F/A/B fetches plus a refresh cycle can
// push the layer-B word past its deadline and produce stale 8x1 strips on
// hardware only (the Verilator bench models SDRAM functionally and never
// exercises controller arbitration).

`define JTFRAME_BA2_PRIO
// Second hardware-only latency source: when sustained CPU/PCM/sprite traffic
// keeps the bus busy, the controller's refresh debt builds until its "help"
// mode forces refresh cycles into every arbitration gap mid-line, blocking
// all banks far beyond the 64-clock tile group budget.  Restrict the forced
// catch-up to horizontal blanking (and ROM download); idle-gap refreshes are
// unaffected and the per-line refresh budget still averages the JEDEC rate.
`define JTFRAME_RFSH_HBLANK
`define JTFRAME_BA3_START 26'h2E0000
`define JTFRAME_PROM_START 26'h6E0000
`define JTFRAME_IOCTL_RD 128
`define JTFRAME_OSD_TEST
`define JTFRAME_NOMRA_DIP
`define JTFRAME_ARX 4
`define JTFRAME_ARY 3
// Defaults emitted by JTFRAME for non-line-buffer MiSTer targets.
// SDRAM read capture phase. Moving capture one cycle later (180SHIFT=1) was
// tried against the DQ[7:0] strip signature and REFUTED by timing: it drives
// SDRAM_CLK from a DDIO cell inverted w.r.t. clk48 instead of the 90-degree
// shifted PLL output, and the SDRAM output paths then miss setup by 1.965 ns
// (they hold +1.9 ns at 180SHIFT=0). Do not re-enable without a new phase plan.
`define JTFRAME_180SHIFT 0
`define JTFRAME_SHIFT 1
`define JTFRAME_LF_HW 9
`define JTFRAME_LF_VW 8
`define JTFRAME_MCLK 48000000
`define JTFRAME_TIMESTAMP 0
`define JTFRAME_MR_FASTIO 0
`define JTFRAME_DIALEMU_LEFT 5
`define JTFRAME_RELEASE
`define JTKCPU_DEBUG
`define GAME_ROM_LEN 26'h6E0000

`endif
