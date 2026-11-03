// 16-bit RAM with byte enables. Port A (CPU): synchronous read/write. Port B: synchronous read only
// (video). Two 8-bit arrays so Quartus infers M10K with independent byte write enables.
// Read-during-write between the ports is not defined (no_rw_check): the CPU write of a location the
// video reads in the same clock yields old or new data, never a bus conflict.
module esd16_ram16 #(parameter AW = 13) (
    input                 clk,
    input      [AW-1:0]   a_addr,
    input      [15:0]     a_din,
    input      [1:0]      a_be,      // [1] = high byte, [0] = low byte
    input                 a_we,
    output reg [15:0]     a_q,
    input      [AW-1:0]   b_addr,
    output reg [15:0]     b_q
);
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] lo [0:(1<<AW)-1];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] hi [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (a_we && a_be[0]) lo[a_addr] <= a_din[7:0];
        a_q[7:0] <= lo[a_addr];
        b_q[7:0] <= lo[b_addr];
    end
    always @(posedge clk) begin
        if (a_we && a_be[1]) hi[a_addr] <= a_din[15:8];
        a_q[15:8] <= hi[a_addr];
        b_q[15:8] <= hi[b_addr];
    end
endmodule
