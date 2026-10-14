// Register-write queue in front of a jtopl2/jt03 FM core.
//
// jtopl/jt12 apply an operator or channel register write lazily: the data
// write latches one pending update (din_copy + one up_* flag, see
// third_party/jtopl/jtopl_mmr.v), which lands only when the target slot next
// passes through the operator pipeline -- up to one full sample cycle later
// (72 x 3 MHz cen = 576 clk = 24 us for the YM3812 here). The next data
// write clears every up_* flag and overwrites din_copy, so a write arriving
// inside that window silently drops the previous one.
//
// Spark Man and Star Fighter write the YM3812 every 17.7-19.3 us (MAME 0.289
// timed register log, 488 and 781 data writes under 24 us apart in the first
// 1000 frames); Hard Head never goes under 35 us. Replaying MAME's register
// stream into the vendored jtopl2 alone reproduced the loss exactly: Star
// Fighter's FM came out 5.7 dB under MAME's YM3812 with whole notes missing
// (channel 0's carrier silent, channel 4's sustained note gone in 40 ms),
// and presenting the same stream with at least 640 clk after every data
// write brought every game to within 1 dB of MAME with an envelope
// correlation of 1.00. In the core that loss is what left the music 6-8 dB
// under MAME and the voice samples sounding far too loud against it.
//
// So the CPU's writes are queued here in order and presented to the chip
// one at a time: each held HOLD clocks, then DATA_GAP clocks of silence
// after a data write (ADDR_GAP after an address write). The CPU never waits;
// the worst burst in MAME's logs queues 65 entries for under 0.9 ms.
// Status reads are untouched (the chips drive their status byte regardless
// of chip select).
module suna8_fm_write_queue #(
    parameter int DEPTH_LOG2 = 7,
    parameter int DATA_GAP   = 640,
    parameter int ADDR_GAP   = 16,
    parameter int HOLD       = 4
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       wr_stb,      // one clk per CPU write transaction
    input  logic       wr_a0,
    input  logic [7:0] wr_data,
    output logic       chip_cs_n,
    output logic       chip_wr_n,
    output logic       chip_a0,
    output logic [7:0] chip_din,
    output logic       overflow     // sticky: a write arrived with the queue full
);
    localparam int DEPTH = 1 << DEPTH_LOG2;

    logic [8:0] mem [0:DEPTH-1];
    logic [DEPTH_LOG2:0] wp, wp_d, rp;
    logic [8:0] rd_q;
    wire full = (wp - rp) == DEPTH[DEPTH_LOG2:0];
    wire avail = wp_d != rp;

    always_ff @(posedge clk) begin
        if (wr_stb && !full)
            mem[wp[DEPTH_LOG2-1:0]] <= {wr_a0, wr_data};
        rd_q <= mem[rp[DEPTH_LOG2-1:0]];
    end

    logic [9:0] wait_cnt;
    logic holding;

    always_ff @(posedge clk) begin
        if (reset) begin
            wp <= '0;
            wp_d <= '0;
            rp <= '0;
            wait_cnt <= '0;
            holding <= 1'b0;
            chip_cs_n <= 1'b1;
            chip_wr_n <= 1'b1;
            chip_a0 <= 1'b0;
            chip_din <= 8'd0;
            overflow <= 1'b0;
        end else begin
            wp_d <= wp;
            if (wr_stb) begin
                if (full)
                    overflow <= 1'b1;
                else
                    wp <= wp + 1'b1;
            end
            if (wait_cnt != 10'd0) begin
                wait_cnt <= wait_cnt - 10'd1;
            end else if (holding) begin
                holding <= 1'b0;
                chip_cs_n <= 1'b1;
                chip_wr_n <= 1'b1;
                wait_cnt <= chip_a0 ? 10'(DATA_GAP) : 10'(ADDR_GAP);
            end else if (avail) begin
                {chip_a0, chip_din} <= rd_q;
                chip_cs_n <= 1'b0;
                chip_wr_n <= 1'b0;
                holding <= 1'b1;
                wait_cnt <= 10'(HOLD - 1);
                rp <= rp + 1'b1;
            end
        end
    end
endmodule
