
module rf_ddr_arb
(
    input  logic        clk,
    input  logic        reset,

    // ---- client R: MiSTer's screen_rotate. Write only, never reads. ------
    input  logic  [7:0] r_burstcnt,
    input  logic [28:0] r_addr,
    input  logic [63:0] r_din,
    input  logic  [7:0] r_be,
    input  logic        r_we,
    output logic        r_busy,

    // ---- client F: the sprite framebuffer. Reads and writes. ------------
    input  logic  [7:0] f_burstcnt,
    input  logic [28:0] f_addr,
    input  logic [63:0] f_din,
    input  logic  [7:0] f_be,
    input  logic        f_we,
    input  logic        f_rd,
    output logic        f_busy,
    output logic [63:0] f_dout,
    output logic        f_dout_ready,

    // ---- the physical port ----------------------------------------------
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE,
    output logic        DDRAM_RD,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY
);

    // ---- rotation's write FIFO ------------------------------------------
    // MLAB, explicitly. The comment here used to say "registers, not an
    // inferred RAM" -- Quartus inferred a RAM anyway and put these 16 x 101
    // bits into FOUR M10K blocks (fit report, 2026-09-09: 16x48, 16x24 and
    // 16x8 altsyncrams under rf_ddr_arb). M10K is the resource at 553/553;
    // six MLABs is six LABs, and it gives the YC encoder's sine table the
    // blocks it needs.
    localparam int FD = 16;                      // power of two
    localparam int AW = $clog2(FD);

    (* ramstyle = "MLAB" *) logic [28:0] q_addr [0:FD-1];
    (* ramstyle = "MLAB" *) logic [63:0] q_din  [0:FD-1];
    (* ramstyle = "MLAB" *) logic  [7:0] q_be   [0:FD-1];
    logic [AW:0] wptr, rptr;                     // one spare bit for full

    wire [AW:0] fcnt   = wptr - rptr;
    wire        fempty = (wptr == rptr);
    wire        ffull  = (fcnt == (AW+1)'(FD));

    // The port takes a command on a cycle where the client drives it and the
    // bridge is not asserting waitrequest -- that is the whole Avalon rule.
    wire        r_take = !fempty && !DDRAM_BUSY;

    always_ff @(posedge clk) begin
        if (reset) begin
            wptr      <= '0;
            rptr      <= '0;

        end else begin
            if (r_we && !ffull) begin
                q_addr[wptr[AW-1:0]] <= r_addr;
                q_din [wptr[AW-1:0]] <= r_din;
                q_be  [wptr[AW-1:0]] <= r_be;
                wptr <= wptr + 1'b1;
            end
            if (r_take) rptr <= rptr + 1'b1;

            // The counterfactual: would the stock fire-and-forget path have
            // lost this pixel? It would, on any cycle waitrequest was high.
        end
    end

    // ---- the mux --------------------------------------------------------
    // Rotation first, and now it holds the port until the write is actually
    // taken rather than offering it for one cycle and hoping.
    // An F write BURST holds the port for its beats: the flip's writer in
    // rf_video_pipe sends eight a command (2026-09-10), and a rotation word
    // slotted between two of them would break the burst. Rotation waits in
    // its FIFO for at most seven beats. (The flip forces rotation off while
    // it runs anyway; this is for the frame where both are changing over.)
    logic [3:0] fw_left;
    always_ff @(posedge clk) begin
        if (reset) fw_left <= 4'd0;
        else if (!DDRAM_BUSY && grant_f && f_we) begin
            if (fw_left != 4'd0) fw_left <= fw_left - 4'd1;
            else if (f_burstcnt > 8'd1) fw_left <= f_burstcnt[3:0] - 4'd1;
        end
    end
    // A command shown to a busy port keeps the grant until it is taken.
    // rf_ddr_rom_port latches the first command it sees while busy and
    // issues THAT one; a rotation word arriving while a sprite framebuffer
    // command waited used to take the grant, so the port issued the sprite
    // command while rotation's FIFO advanced as if its word had gone (a
    // rotation pixel lost) and the sprite side, still told busy, issued its
    // command a second time (eight read beats nobody had asked for).
    logic shown_r, shown_f;
    wire grant_r = shown_r | (!shown_f && !fempty && (fw_left == 4'd0));
    wire f_want  = f_we | f_rd;
    wire grant_f = ~grant_r & f_want;
    always_ff @(posedge clk) begin
        shown_r <= !reset && DDRAM_BUSY && grant_r;
        shown_f <= !reset && DDRAM_BUSY && grant_f;
    end

    always_comb begin
        if (grant_r) begin
            DDRAM_BURSTCNT = 8'd1;               // screen_rotate ties this to 1
            DDRAM_ADDR     = q_addr[rptr[AW-1:0]];
            DDRAM_DIN      = q_din [rptr[AW-1:0]];
            DDRAM_BE       = q_be  [rptr[AW-1:0]];
            DDRAM_WE       = 1'b1;
            DDRAM_RD       = 1'b0;
        end else if (grant_f) begin
            DDRAM_BURSTCNT = f_burstcnt;
            DDRAM_ADDR     = f_addr;
            DDRAM_DIN      = f_din;
            DDRAM_BE       = f_be;
            DDRAM_WE       = f_we;
            DDRAM_RD       = f_rd;
        end else begin
            DDRAM_BURSTCNT = 8'd1;
            DDRAM_ADDR     = 29'd0;
            DDRAM_DIN      = 64'd0;
            DDRAM_BE       = 8'd0;
            DDRAM_WE       = 1'b0;
            DDRAM_RD       = 1'b0;
        end
    end

    // screen_rotate ignores this (that is the bug), but drive it correctly:
    // the only state in which it genuinely cannot be served is a full FIFO.
    assign r_busy = ffull;
    assign f_busy = DDRAM_BUSY | grant_r;

    // Rotation never reads, so every returning word is the framebuffer's.
    assign f_dout       = DDRAM_DOUT;
    assign f_dout_ready = DDRAM_DOUT_READY;

    // r_burstcnt is unused: screen_rotate ties it to a constant 1 and the
    // FIFO replays single words. Referenced so the port is not dangling.
    wire _unused_r_burstcnt = &{1'b0, r_burstcnt};

endmodule
