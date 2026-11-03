// Main DECO16 (6502 + CPU16) @ ~2 MHz
// Adapted from Arcade-ExpressRaider_MiSTer rtl/cpu/mcpu.v

module mcpu #(
  parameter CLK_DIV = 23
)(
  input         clk_sys,
  input         reset,
  input         irq_n,
  input         nmi_n,          // tie high where the board has no NMI source
  input         vblank,
  input         ready,          // SDRAM ROM ready (RDY)
  input         opcode_decrypt, // Liberation/Dual Assault opcode permutation
  input         bank_bit2,      // Kamikaze/Yellow Cab use bit 2; others bit 0
  input  [7:0]  io0_data,
  input  [7:0]  io1_data,
  output [15:0] cpu_ab,
  input  [7:0]  cpu_din,
  output [7:0]  cpu_dout,
  output        rw,
  output        bank_en,
  output        sync
);

// 48 MHz / 24 ≈ 2 MHz
wire cen_2m;
clk_en #(CLK_DIV) cpu_clk_en(clk_sys, cen_2m);

wire [7:0]  din, dout;
wire [15:0] addr;
wire        sync_i;
assign sync = sync_i;

// One 6502 for both CPUs. The old `ifdef SYNTH` branch selected the visual6502
// netlist (chip_6502) for hardware and Arlet for simulation -- but SYNTH was
// never defined in the .qsf, so hardware would silently have built the Arlet
// path anyway, and the sound CPU needs Arlet's IR hook for the DECO222
// decrypt. Carrying two divergent CPUs, only one of which was ever exercised,
// was a latent trap.
wire m6502_we;
assign rw = ~m6502_we;

wire [5:0] dbg_state;  // unused outside simulation probes

cpu6502 #(.INPUT_HELD_ON_WAIT(1)) M6502(
  .clk   ( clk_sys  ),
  .CE    ( cen_2m   ),
  .reset ( reset    ),
  .AB    ( addr     ),
  .DI    ( din      ),
  .DO    ( dout     ),
  .WE    ( m6502_we ),
  .IRQ   ( ~irq_n   ),
  .NMI   ( ~nmi_n   ),
  .RDY_IN( ready   ),
  .SYNC  ( sync_i   ),
  .STATE ( dbg_state ),
  .COND_TRUE (      ),
  .DECRYPT ( 1'b0   ),   // DECO16 main CPU is not encrypted
  .IRQ_ACK (        )    // main IRQ is level/ack-via-IO[8], not HOLD_LINE
);

CPU16 CPU16(
  .clk      ( clk_sys   ),
  // Same clock enable and wait-state as the 6502 core. A stalled bus cycle must not
  // consume a custom-opcode operand or overwrite its registered data.
  .cen      ( cen_2m ),
  .ready    ( ready ),
  .reset    ( reset     ),
  .ABI      ( addr      ),
  .ABO      ( cpu_ab    ),
  .CPU_DBI  ( dout      ),
  .CPU_DBO  ( din       ),
  .DBI      ( cpu_din   ),
  .DBO      ( cpu_dout  ),
  .SYNC     ( sync_i    ),
  .RW       ( rw        ),
  .VB       ( vblank    ),
  .bank_en  ( bank_en   ),
  .io0_data ( io0_data  ),
  .io1_data ( io1_data  ),
  .opcode_decrypt(opcode_decrypt),
  .bank_bit2(bank_bit2)
);

endmodule
