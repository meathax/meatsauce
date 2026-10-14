// Transactional bundled-data clock-domain crossing for one SDRAM client.
//
// The source owns at most one transaction at a time.  Its request payload is
// held until the destination completes the transaction.  A toggle, passed
// through SYNC_STAGES synchronizer registers, announces the stable payload to
// the destination.  The response uses the same scheme in the opposite
// direction.
//
// src_req may be either a pulse or a level held until src_ack.  src_ack is a
// one-source-clock pulse.  dst_req is a one-destination-clock pulse; dst_ack
// may be a pulse or a stretched level.
module s24_sdram_cdc #(
    parameter integer REQ_WIDTH = 1,
    parameter integer RSP_WIDTH = 1,
    // Synchronizer depth on each toggle.
    //
    // 2 is mandatory for genuinely asynchronous clocks and stays the default,
    // so any future instance of this module is safe without thinking about it.
    //
    // 1 is correct ONLY when src_clk and dst_clk come from one PLL VCO at an
    // integer ratio with aligned edges.  That is this core's case: clk_sys is
    // VCO/26 and clk_ram is VCO/13, an exact phase-locked 2:1 pair, and
    // Arcade-SegaSystem24.sdc already places both in a single clock group, so
    // each toggle crossing is an ordinary fully-timed register-to-register
    // path with no metastability to resolve.  The second stage then buys
    // nothing but latency -- one dst_clk on the request plus one src_clk on
    // the response, 1.5 clk_sys (31 ns) per access.  That was not free: a CPU
    // read took roughly 16 clk_sys against the 68000's ~9.7 clk_sys DTACK
    // deadline, so every bus cycle carried wait states and the whole machine
    // ran slow (measured on hardware: CPU-B stalled 40-50% of every frame).
    //
    // Depth 1 deliberately PRESERVES the payload stability window that the
    // SDC's multicycle exception on dst_payload/src_response is written
    // against.  With one stage req_hold is still captured two dst_clk periods
    // after it is written, and rsp_hold two src_clk periods -- exactly what
    // "set_multicycle_path -setup -end 2" declares, so that exception needs no
    // change and the fitter's problem is unaltered.
    //
    // Do NOT reduce this to 0.  That would cut both windows to a single period
    // and tighten a constraint whose relaxed form exists precisely because the
    // fitter could not otherwise close hold on the 128-bit cdc_p2 payload: it
    // inserted >2.3 us of hold-fixing routing delay, exhausted routing in that
    // region and still missed, which corrupts read data as garbage tile and
    // sprite texture on silicon.  Verilator has no routing delay and cannot
    // reproduce that failure, so simulation passing proves nothing here.
    parameter integer SYNC_STAGES = 2
) (
    input  logic                 reset,

    input  logic                 src_clk,
    input  logic                 src_req,
    input  logic [REQ_WIDTH-1:0] src_payload,
    output logic                 src_ack,
    output logic [RSP_WIDTH-1:0] src_response,

    input  logic                 dst_clk,
    output logic                 dst_req,
    output logic [REQ_WIDTH-1:0] dst_payload,
    input  logic                 dst_ack,
    input  logic [RSP_WIDTH-1:0] dst_response
);
    logic                 req_toggle;
    logic [REQ_WIDTH-1:0] req_hold;
    logic                 src_busy;
    logic                 src_armed;

    logic                 rsp_seen;
    logic [RSP_WIDTH-1:0] rsp_hold;

    logic                 req_seen;
    logic                 dst_busy;
    logic                 rsp_toggle;

    // Cross-domain views of the two toggles: the response toggle as observed
    // in src_clk, and the request toggle as observed in dst_clk.
    logic rsp_toggle_src;
    logic req_toggle_dst;

    generate
    if (SYNC_STAGES <= 1) begin : g_sync1
        // Related-clock crossing: one register each way.  See SYNC_STAGES.
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic rsp_sync_m;
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic req_sync_m;

        always_ff @(posedge src_clk or posedge reset) begin
            if (reset) rsp_sync_m <= 1'b0;
            else       rsp_sync_m <= rsp_toggle;
        end
        always_ff @(posedge dst_clk or posedge reset) begin
            if (reset) req_sync_m <= 1'b0;
            else       req_sync_m <= req_toggle;
        end

        assign rsp_toggle_src = rsp_sync_m;
        assign req_toggle_dst = req_sync_m;
    end
    else begin : g_sync2
        // Asynchronous crossing: the standard two-flop synchronizer.
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic rsp_sync_m;
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic rsp_sync_s;
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic req_sync_m;
        (* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
        logic req_sync_s;

        always_ff @(posedge src_clk or posedge reset) begin
            if (reset) begin
                rsp_sync_m <= 1'b0;
                rsp_sync_s <= 1'b0;
            end else begin
                rsp_sync_m <= rsp_toggle;
                rsp_sync_s <= rsp_sync_m;
            end
        end
        always_ff @(posedge dst_clk or posedge reset) begin
            if (reset) begin
                req_sync_m <= 1'b0;
                req_sync_s <= 1'b0;
            end else begin
                req_sync_m <= req_toggle;
                req_sync_s <= req_sync_m;
            end
        end

        assign rsp_toggle_src = rsp_sync_s;
        assign req_toggle_dst = req_sync_s;
    end
    endgenerate

    // Source-domain request launch and response receive.
    always_ff @(posedge src_clk or posedge reset) begin
        if (reset) begin
            req_toggle  <= 1'b0;
            req_hold    <= '0;
            src_busy    <= 1'b0;
            src_armed   <= 1'b1;
            rsp_seen    <= 1'b0;
            src_ack     <= 1'b0;
            src_response<= '0;
        end else begin
            src_ack    <= 1'b0;

            // A held request is one transaction.  Do not re-arm until the
            // requester has observed src_ack and dropped the level.
            if (!src_req)
                src_armed <= 1'b1;

            if (!src_busy && src_req && src_armed) begin
                req_hold   <= src_payload;
                req_toggle <= ~req_toggle;
                src_busy   <= 1'b1;
                src_armed  <= 1'b0;
            end

            if (src_busy && rsp_toggle_src != rsp_seen) begin
                // rsp_hold was made stable before rsp_toggle traversed the
                // synchronizer.
                src_response <= rsp_hold;
                rsp_seen     <= rsp_toggle_src;
                src_ack      <= 1'b1;
                src_busy     <= 1'b0;
            end
        end
    end

    // Destination-domain request receive and response launch.
    always_ff @(posedge dst_clk or posedge reset) begin
        if (reset) begin
            req_seen   <= 1'b0;
            dst_req    <= 1'b0;
            dst_payload<= '0;
            dst_busy   <= 1'b0;
            rsp_hold   <= '0;
            rsp_toggle <= 1'b0;
        end else begin
            dst_req    <= 1'b0;

            if (!dst_busy && req_toggle_dst != req_seen) begin
                // req_hold has been stable throughout toggle synchronization.
                dst_payload <= req_hold;
                req_seen    <= req_toggle_dst;
                dst_req     <= 1'b1;
                dst_busy    <= 1'b1;
            end

            if (dst_busy && dst_ack) begin
                rsp_hold   <= dst_response;
                rsp_toggle <= ~rsp_toggle;
                dst_busy   <= 1'b0;
            end
        end
    end
endmodule
