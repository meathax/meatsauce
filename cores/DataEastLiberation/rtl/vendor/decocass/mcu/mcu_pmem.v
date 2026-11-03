/*============================================================================
  MCU Program Memory (1 KB) — dual-port BRAM for UPI41 core

  Port A: Write-only, driven by rom_loader (task 25) — clk_a (clk_sys)
  Port B: Read-only,  driven by upi41_core prog-mem ctrl — clk_b (8041 clock)

  MCU-CLK-REALCLK-2026-06-04: Port B is now clocked by the 8041's OWN real clock
  (clk_8041), not clk_sys. The 8041 runs in its own clock domain (like Arcade-
  JunoFirst's 8039), so its program fetches must be synchronous to that clock.
  Writes (rom_loader) stay on clk_sys; they only happen during ioctl_download
  (8041 held in reset), so the two ports never collide.

  REALCLK-REVERT-2026-06-04: REVERTED — the i8041_top instance now feeds clk_b=clk_sys
  again (8041 back on clk_sys, no host-bus CDC). This module is domain-agnostic (clk_b
  is just a port), so nothing changes here; both ports are once more on clk_sys.

  i8041 ROM size: 1024 bytes (10-bit address)
  ============================================================================*/

`timescale 1 ps / 1 ps

module mcu_pmem (
    // Port A: write-only (rom_loader, clk_sys domain)
    input  wire         clk_a,
    input  wire         we_a,
    input  wire [9:0]   addr_a,
    input  wire [7:0]   din_a,
    // Port B: read-only (upi41_core.pmem_addr_o, 8041 clock domain)
    input  wire         clk_b,
    input  wire [10:0]  addr_b,      // upi41_core provides 11 bits, we use [9:0]
    output reg [7:0]    dout_b
);

    localparam RAM_DEPTH = 1024;      // 2^10 bytes

    reg [7:0] mem [0:RAM_DEPTH-1];

    // Port A: synchronous write (clk_a)
    always @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= din_a;
    end

    // Port B: synchronous read (clk_b) — registered output
    always @(posedge clk_b) begin
        dout_b <= mem[addr_b[9:0]];
    end

endmodule
