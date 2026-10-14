`timescale 1ns/1ps
`default_nettype none
// MiSTer persistence adapter for the 16Kx16 Williams CMOS image in SDRAM.
// Upload reads share the main-RAM SDRAM channel after the game core has paused
// at a bus-idle boundary; ioctl_wait holds HPS until the word is cached.
module narc_nvram_if #(
  parameter logic [24:1] CMOS_WORD_BASE = 24'h810000
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        ioctl_upload,
  input  wire [15:0] ioctl_index,
  input  wire        ioctl_rd,
  input  wire [26:0] ioctl_addr,
  output logic [7:0] ioctl_din,
  output logic       ioctl_wait,
  output wire        active,

  output logic       main_req,
  output wire        main_we,
  output logic [24:1] main_addr,
  output wire [15:0] main_din,
  output wire [1:0]  main_be,
  input  wire [47:0] main_dout,
  input  wire        main_ack
);
  assign active   = ioctl_upload && (ioctl_index == 16'd3);
  assign main_we  = 1'b0;
  assign main_din = 16'h0000;
  assign main_be  = 2'b11;

  logic waiting;
  logic cache_valid;
  logic [13:0] cache_word_addr;
  logic [15:0] cache_word;
  wire [13:0] wanted_word = ioctl_addr[14:1];
  wire cache_hit = cache_valid && (cache_word_addr == wanted_word);

  always_comb begin
    ioctl_din  = ioctl_addr[0] ? cache_word[15:8] : cache_word[7:0];
    // Only stall an actual upload read. Address setup cycles need no response.
    ioctl_wait = active && ioctl_rd && !cache_hit;
  end

  always_ff @(posedge clk) begin
    main_req <= 1'b0;
    if (rst || !active) begin
      waiting <= 1'b0;
      cache_valid <= 1'b0;
      cache_word_addr <= 14'd0;
      cache_word <= 16'h0000;
      main_addr <= CMOS_WORD_BASE;
    end else begin
      if (!waiting && ioctl_rd && !cache_hit && !main_ack) begin
        main_req  <= 1'b1;
        main_addr <= CMOS_WORD_BASE + {{10{1'b0}}, wanted_word};
        cache_word_addr <= wanted_word;
        cache_valid <= 1'b0;
        waiting <= 1'b1;
      end else if (waiting && main_ack) begin
        cache_word <= main_dout[15:0];
        cache_valid <= 1'b1;
        waiting <= 1'b0;
      end
      // An address change while a previous request completes simply causes a
      // second request; ioctl_wait remains asserted for the new byte.
    end
  end
endmodule
`default_nettype wire
