// EARLY_DONE=1 requires the qualified video client to withdraw req on the done-sampling edge.
// Request arbiter + 64-bit burst assembler for ONE bank of jtframe_sdram64 (4-word burst, 16-bit words).
//   req[i] is held by source i until done[i] (one clk pulse, blk valid in that clk and held).
//   waddr[i] is the 22-bit WORD address of the burst start (low 2 bits must be 0).
//   Lowest index has priority. Contract with jtframe_sdram64: rd is held until ack (st[READ]); the first
//   data word is on sd_dout in the clock where sd_dst is high, the next three words follow in the next
//   three clocks (same convention as jtframe_romrq_bcache).
module esd16_bankport #(parameter N = 1, EARLY_DONE = 0) (
    input                  clk,
    input                  rst,
    input                  stop_new,
    output                 active,
    input      [N-1:0]     req,
    input      [N*22-1:0]  waddr,
    output wire [N-1:0]    done,
    output wire [63:0]     blk,
    output reg             sd_rd,
    output reg [21:0]      sd_addr,
    input                  sd_ack,
    input                  sd_dst,
    input      [15:0]      sd_dout
);
    localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1, S_DST = 2'd2, S_BEAT = 2'd3;
    reg [N-1:0] done_q;
    reg [63:0] blk_q;
    reg [1:0]         st;
    reg [1:0]         cnt;
    reg [N-1:0]       gnt;
    integer           i;
    reg               found;
    reg [N-1:0]       pick;
    reg [21:0]        paddr;

    // Keep a request accepted before stop_new drains through its final data beat.
    // Requests waiting in S_IDLE remain owned by their caller and can be retried.
    assign active = (st != S_IDLE);

    // Optional video path consumes the final registered controller word on the
    // same edge as the assembler. Legacy clients retain their registered done.
    assign done = EARLY_DONE ? ((!rst && st == S_BEAT && cnt == 2'd3) ? gnt : {N{1'b0}}) : done_q;
    assign blk = (EARLY_DONE && st == S_BEAT && cnt == 2'd3) ? {sd_dout,blk_q[47:0]} : blk_q;

    always @* begin
        found = 1'b0; pick = {N{1'b0}}; paddr = 22'd0;
        for (i = 0; i < N; i = i + 1)
            if (!found && req[i]) begin
                found = 1'b1; pick[i] = 1'b1; paddr = waddr[i*22 +: 22];
            end
    end

    always @(posedge clk) begin
        done_q <= {N{1'b0}};
        if (rst) begin
            st <= S_IDLE; sd_rd <= 1'b0; gnt <= {N{1'b0}}; cnt <= 2'd0;
        end else begin
            case (st)
            S_IDLE: if (found && !(|done) && !stop_new) begin
                gnt <= pick; sd_addr <= paddr; sd_rd <= 1'b1; st <= S_ISSUE;
            end
            S_ISSUE: if (sd_ack) begin sd_rd <= 1'b0; st <= S_DST; end
            S_DST: if (sd_dst) begin
                blk_q[15:0] <= sd_dout; cnt <= 2'd1; st <= S_BEAT;
            end
            S_BEAT: begin
                case (cnt)
                    2'd1: blk_q[31:16] <= sd_dout;
                    2'd2: blk_q[47:32] <= sd_dout;
                    default: blk_q[63:48] <= sd_dout;
                endcase
                cnt <= cnt + 2'd1;
                if (cnt == 2'd3) begin done_q <= gnt; st <= S_IDLE; end
            end
            endcase
        end
    end
endmodule
