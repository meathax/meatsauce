//============================================================================
// Word line-cache for 6502 ROM fetches from SDRAM.
// Holds last SDRAM word; ready=0 on miss until hit after ack capture.
// ack from sdram is stretched ≥2 clk_ram cycles so clk_sys (1/2) never misses.
//============================================================================

module rom_cache (
  input             clk,
  input             reset,

  input             rom_cs,
  input             cpu_rw,
  input      [15:0] cpu_addr,
  output reg  [7:0] cpu_data,
  output reg        ready,

  output reg        req,
  output     [24:1] addr,
  input      [15:0] dout,
  input             ack,

  input      [24:0] sdram_base
);

reg        valid;
reg [24:1] tag;
reg [15:0] data;
reg        pending;
reg [24:0] pend_byte;
reg        ack_d, ack_dd;

wire [24:0] byte_addr = sdram_base + {9'd0, cpu_addr};
wire        want = rom_cs && cpu_rw;
wire        hit  = want && valid && (tag == byte_addr[24:1]);

// req and pend_byte are registered together and held through the reply.
// The SDRAM port needs only that transaction address. Exposing the live CPU
// address while idle creates a long decode path into its faster clock domain.
assign addr = pend_byte[24:1];

always @(posedge clk) begin
  if (reset) begin
    ack_d  <= 1'b0;
    ack_dd <= 1'b0;
  end else begin
    ack_d  <= ack;
    ack_dd <= ack_d;
  end
end
// Stretched ack: any high after sync flops (sdram holds ack ≥2 clk_ram)
wire ack_seen = ack_d | ack_dd;

always @(posedge clk) begin
  if (reset) begin
    valid     <= 1'b0;
    pending   <= 1'b0;
    req       <= 1'b0;
    ready     <= 1'b1;
    cpu_data  <= 8'h00;
    tag       <= 24'd0;
    data      <= 16'd0;
    pend_byte <= 25'd0;
  end else begin
    if (ack_seen && pending) begin
      data     <= dout;
      tag      <= pend_byte[24:1];
      valid    <= 1'b1;
      pending  <= 1'b0;
      req      <= 1'b0;
      // The address may change while the memory request is in flight. Only
      // release the current read when this word actually satisfies it.
      ready    <= !want || (byte_addr[24:1] == pend_byte[24:1]);
      cpu_data <= byte_addr[0] ? dout[15:8] : dout[7:0];
    end else if (want && hit) begin
      ready     <= 1'b1;
      cpu_data <= byte_addr[0] ? data[15:8] : data[7:0];
    end else if (want && !hit && !pending) begin
      ready     <= 1'b0;
      // The synchronized acknowledgement is stretched. A new transaction
      // must wait for it to fall or the old word can be tagged as the new one.
      if (!ack_seen) begin
        req       <= 1'b1;
        pending   <= 1'b1;
        pend_byte <= byte_addr;
        valid     <= 1'b0;
      end
    end else if (!want) begin
      req   <= 1'b0;
      ready <= 1'b1;
    end else begin
      // Keep the CPU stopped for the whole SDRAM miss. `ready` is registered
      // deliberately: a combinational ready=(hit) path feeds the CPU address
      // back into `want` and creates a large Quartus combinational loop.
      ready <= 1'b0;
    end
  end
end

endmodule
