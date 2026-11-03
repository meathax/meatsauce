// i8751 MCU for the DEC8 boards (PLAN M2): jt8051 with its program ROM and
// internal RAM, wired exactly as jtframe's jtframe_8751mcu (jtcores
// a72a4460, the wrapper jt8051 is verified in): the ROM address is
// registered every clock, ROM and RAM reads are registered on `cen`, the
// RAM is cleared at reset (MAME's internal RAM also starts at zero).
//
// `cen` is the 8 MHz oscillator enable (96 MHz / 12): a machine cycle is
// 12 of them (1.5 us), MAME's I8751 at 8 MHz (dec8.cpp:1997, 2111, 2426).
//
// The 4 KB program ROM is loaded through the `i_rom_*` port before reset is
// released (MRA download in M4, the harness in M2).

module d8_mcu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cen,

    input  logic        i_int0n,
    input  logic        i_int1n,
    input  logic [7:0]  i_p0,
    input  logic [7:0]  i_p0_force,
    input  logic [7:0]  i_p1,
    input  logic [7:0]  i_p2,
    input  logic [7:0]  i_p3,
    output logic [7:0]  o_p0,
    output logic [7:0]  o_p1,
    output logic [7:0]  o_p2,
    output logic [7:0]  o_p3,
    // SFR write events (MAME port_out callbacks fire on every port write)
    output logic        o_sfr_wr,
    output logic [7:0]  o_sfr_wa,
    output logic [7:0]  o_sfr_wd,
    output logic        o_xacc,        // MOVX access (counted: none expected)

    input  logic        i_rom_we,
    input  logic [11:0] i_rom_addr,
    input  logic [7:0]  i_rom_din
);

  wire        rst = !rst_n;
  logic [7:0] rom_data, ram_q;
  logic [15:0] rom_addr;
  wire  [15:0] pre_rom;
  wire  [6:0]  ram_addr;
  wire  [7:0]  ram_data;
  wire         ram_we;
  wire  [7:0]  x_dout;
  wire  [15:0] x_addr;
  wire         x_wr, x_acc;

  // program ROM: port 0 = loader, port 1 = CPU read on cen
  logic [7:0] rom [0:4095] /* verilator public_flat_rw */;
  always_ff @(posedge clk) begin
    if (i_rom_we) rom[i_rom_addr] <= i_rom_din;
  end
  always_ff @(posedge clk) if (cen) rom_data <= rom[rom_addr[11:0]];
  always_ff @(posedge clk) rom_addr <= pre_rom;

  // internal RAM, 128 bytes, cleared during reset (jtframe_ram_rst)
  logic [7:0] ram [0:127] /* verilator public_flat_rd */;
  logic [6:0] rst_cnt;
  logic       rstl;
  always_ff @(posedge clk) begin
    rstl <= rst;
    if (rstl) rst_cnt <= rst_cnt + 7'd1;
    else rst_cnt <= '0;
    if (rstl) ram[rst_cnt] <= 8'd0;
    else if (cen) begin
      ram_q <= ram[ram_addr];
      if (ram_we) ram[ram_addr] <= ram_data;
    end
  end

  logic sfr_wr;
  logic [7:0] sfr_wa, sfr_wd;
  /* verilator lint_off PINCONNECTEMPTY */
  jt8051 u_mcu (
      .rst(rst), .clk, .cen,
      .int0n(i_int0n), .int1n(i_int1n),
      .p0_i(i_p0), .p1_i(i_p1), .p2_i(i_p2), .p3_i(i_p3),
      .p0_o(o_p0), .p1_o(o_p1), .p2_o(o_p2), .p3_o(o_p3),
      .rom_data, .rom_addr(pre_rom),
      .ram_din(ram_q), .ram_dout(ram_data), .ram_addr, .ram_we,
      .x_din(8'hFF), .x_dout, .x_addr, .x_wr, .x_acc,
      .sfr_wr, .sfr_wa, .sfr_wd, .p0_force(i_p0_force));
  /* verilator lint_on PINCONNECTEMPTY */
  assign o_sfr_wr = sfr_wr;
  assign o_sfr_wa = sfr_wa;
  assign o_sfr_wd = sfr_wd;
  assign o_xacc   = x_acc;

endmodule
