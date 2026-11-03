// -----------------------------------------------------------------------------
// exterm_slave_mem.sv -- slave GSP memory fabric (FG VRAM + 1 MB DRAM).
// Thin wrapper over the shared field/backend engine exterm_master_mem with
// IS_SLAVE=1 (MAME slave_map: VRAM when a[26]=0, DRAM when a[26]=1). The host
// port accesses reach this module through the same request stage as the slave
// core (see exterm_cpu_sys).
// -----------------------------------------------------------------------------
`default_nettype none
module exterm_slave_mem (
  input  wire        clk,
  input  wire        rst,
  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [5:0]  size,
  input  wire [31:0] wdata,
  input  wire        pix,
  input  wire        srt_on,
  input  wire [2:0]  eng,
  input  wire [1:0]  esub,
  input  wire        ers,
  input  wire        srt_clr,
  output wire [31:0] rdata,
  output wire        ack,

  output wire        sd_req,
  output wire        sd_we,
  output wire [23:0] sd_addr,
  output wire [15:0] sd_din,
  output wire [1:0]  sd_be,
  output wire [2:0]  sd_burst,
  input  wire [63:0] sd_dout,
  input  wire        sd_ack,

  output wire        v_req,
  output wire        v_we,
  output wire [15:0] v_addr,
  output wire [15:0] v_wdata,
  output wire [1:0]  v_be,
  output wire        v_srt_rd,
  output wire        v_srt_wr,
  input  wire [15:0] v_rdata,
  input  wire        v_ack
);
  exterm_master_mem #(.IS_SLAVE(1'b1)) u_mem (
    .clk(clk), .rst(rst),
    .req(req), .we(we), .addr(addr), .size(size), .wdata(wdata),
    .pix(pix), .srt_on(srt_on), .eng(eng), .esub(esub), .ers(ers), .srt_clr(srt_clr), .rdata(rdata), .ack(ack),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
    .sd_be(sd_be), .sd_burst(sd_burst), .sd_dout(sd_dout), .sd_ack(sd_ack),
    .rom_inval(1'b0),
    .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_wdata(v_wdata), .v_be(v_be),
    .v_srt_rd(v_srt_rd), .v_srt_wr(v_srt_wr), .v_rdata(v_rdata), .v_ack(v_ack),
    .pal_we(), .pal_addr(), .pal_wdata(), .pal_be(), .pal_rdata(16'h0),
    .nv_we(), .nv_addr(), .nv_wdata(), .nv_be(), .nv_rdata(16'h0),
    .per_req(), .per_we(), .per_sel(), .per_wdata(), .per_rdata(16'h0), .per_ack(1'b0)
  );
endmodule
`default_nettype wire
