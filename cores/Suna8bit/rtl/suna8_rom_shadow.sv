// On-chip copy of one CPU's hottest ROM window, so those reads never wait on
// the shared SDRAM cache. The original boards run every Z80 with zero wait
// states; the SDRAM path stalls a CPU on each cache miss.
//
// Filled from the same index-0 download stream that is written to SDRAM
// (media_wr_valid/addr/data from suna8_rom_loader), so it holds exactly the
// raw bytes the SDRAM holds at [BASE, BASE+DEPTH). Every per-profile address
// scramble and opcode/data decryption stays downstream, on the raw byte.
//
// One write port (download only; the CPUs are held in reset while
// ioctl_download is high) and one unconditional registered read port, so it
// infers M10K. rd_addr_q is the address the current rd_q belongs to: a reader
// treats the byte as valid only when rd_addr_q equals the address it is
// presenting now, which makes the one-clock read latency safe by construction.
module suna8_rom_shadow
#(
    parameter int DEPTH = 32768,
    parameter int AW = 15,
    parameter logic [24:0] BASE = 25'h000000
)
(
    input  logic clk,
    input  logic wr_valid,
    input  logic [24:0] wr_addr,
    input  logic [7:0] wr_data,
    input  logic [AW-1:0] rd_addr,
    output logic [7:0] rd_q,
    output logic [AW-1:0] rd_addr_q
);

    logic [7:0] mem [0:DEPTH-1];
    // An address below BASE wraps to far above DEPTH, so one unsigned
    // compare checks both edges of the window.
    wire [24:0] wr_offset = wr_addr - BASE;
    wire wr_hit = wr_valid && (wr_offset < 25'(DEPTH));

    always_ff @(posedge clk) begin
        if (wr_hit)
            mem[wr_offset[AW-1:0]] <= wr_data;
        rd_q <= mem[rd_addr];
        rd_addr_q <= rd_addr;
    end

endmodule
