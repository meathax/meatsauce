// Read-only 2- or 8-slot cache of 64-bit SDRAM blocks with sequential prefetch.
// One instance serves one byte-addressed ROM reader (68000 program, Z80 program or OKI samples).
//   a      : region-relative byte address (combinational from the consumer)
//   en     : the consumer is actually accessing (misses are only requested while en=1)
//   ok     : the addressed block is cached; data is valid in the same clock (combinational)
//   req/req_blk/done/blk : request port to esd16_bankport (req held until done)
// A demand miss replaces the slot that is not most recently used (invalid slots first). A hit on block n
// starts a prefetch of block n+1 into the other slot when it is not cached yet.
module esd16_blkcache #(
    parameter BAW      = 16,    // block index width (region bytes = 8 * 2**BAW)
    parameter DW       = 16,    // 8 or 16 output bits
    parameter SLOTS = 2,
    parameter PREFETCH = 1
)(
    input                    clk,
    input                    inv,       // invalidate everything (download / reset)
    input                    en,
    input      [BAW+2:0]     a,
    output     [DW-1:0]      data,
    output                   ok,
    output reg               req,
    output reg [BAW-1:0]     req_blk,
    input                    done,
    input      [63:0]        blk
);
    generate if (SLOTS==2) begin:g_two
    reg [63:0]    d0, d1;
    reg [BAW-1:0] t0, t1, ftag;
    reg           v0, v1, mru, fslot, busy;

    wire [BAW-1:0] cb   = a[BAW+2:3];
    wire [BAW-1:0] nb   = cb + {{(BAW-1){1'b0}}, 1'b1};
    wire           hit0 = v0 && (t0 == cb);
    wire           hit1 = v1 && (t1 == cb);
    assign ok = hit0 | hit1;
    wire [63:0] sel = hit0 ? d0 : d1;
        if (DW == 16) begin : g16
            assign data = sel[16*a[2:1] +: 16];
        end else begin : g8
            assign data = sel[8*a[2:0] +: 8];
        end

    wire nb_cached = (v0 && t0 == nb) || (v1 && t1 == nb) || (busy && ftag == nb);
    wire nb_wrap   = (nb == {BAW{1'b0}});

    always @(posedge clk) begin
        if (inv) begin
            v0 <= 1'b0; v1 <= 1'b0; busy <= 1'b0; req <= 1'b0; mru <= 1'b0;
        end else if (busy) begin
            if (done) begin
                busy <= 1'b0; req <= 1'b0;
                // The reader may have moved back to the replacement slot while
                // this prefetch was in flight. Never revoke a live cache hit:
                // the CPU may already have sampled DTACK for this word.
                // Discard that speculative fill; a later miss can request it.
                if (en && ((fslot && hit1) || (!fslot && hit0)) && cb != ftag) begin
                    mru <= hit1;
                end else begin
                    if (fslot) begin d1 <= blk; t1 <= ftag; v1 <= 1'b1; end
                    else       begin d0 <= blk; t0 <= ftag; v0 <= 1'b1; end
                    mru <= fslot;
                end
            end
        end else if (en) begin
            if (!ok) begin                       // demand miss
                busy <= 1'b1; req <= 1'b1; req_blk <= cb; ftag <= cb;
                fslot <= !v0 ? 1'b0 : (!v1 ? 1'b1 : ~mru);
            end else begin
                mru <= hit0 ? 1'b0 : 1'b1;
                if (PREFETCH != 0 && !nb_cached && !nb_wrap) begin
                    busy <= 1'b1; req <= 1'b1; req_blk <= nb; ftag <= nb;
                    fslot <= hit0 ? 1'b1 : 1'b0;
                end
            end
        end
    end
    end else begin:g_many
    localparam IW = $clog2(SLOTS);
    reg [63:0] blocks [0:SLOTS-1];
    reg [BAW-1:0] tags [0:SLOTS-1];
    reg [SLOTS-1:0] valid;
    reg [IW-1:0] victim, fill_slot;
    reg [BAW-1:0] fill_tag;
    reg busy;
    wire [BAW-1:0] cb = a[BAW+2:3];
    wire [BAW-1:0] nb = cb + {{(BAW-1){1'b0}},1'b1};
    reg hit, nb_cached, invalid_found;
    reg [IW-1:0] hit_slot, empty_slot;
    integer i;
    always @* begin
        hit=0; hit_slot=0; nb_cached=busy && fill_tag==nb;
        invalid_found=0; empty_slot=0;
        for (i=0;i<SLOTS;i=i+1) begin
            if (valid[i] && tags[i]==cb) begin hit=1; hit_slot=i[IW-1:0]; end
            if (valid[i] && tags[i]==nb) nb_cached=1;
            if (!valid[i] && !invalid_found) begin invalid_found=1; empty_slot=i[IW-1:0]; end
        end
    end
    assign ok=hit;
    wire [63:0] selected=blocks[hit_slot];
    if (DW==16) begin:g16
        assign data=selected[16*a[2:1]+:16];
    end else begin:g8
        assign data=selected[8*a[2:0]+:8];
    end
    wire [IW-1:0] next_victim = victim==hit_slot ? victim+1'b1 : victim;
    always @(posedge clk) begin
        if (inv) begin valid<=0; busy<=0; req<=0; victim<=0; end
        else if (busy) begin
            if (done) begin
                busy<=0; req<=0;
                if (!(en && hit && hit_slot==fill_slot && cb!=fill_tag)) begin
                    blocks[fill_slot]<=blk; tags[fill_slot]<=fill_tag;
                    valid[fill_slot]<=1; victim<=fill_slot+1'b1;
                end
            end
        end else if (en) begin
            if (!hit) begin
                busy<=1; req<=1; req_blk<=cb; fill_tag<=cb;
                fill_slot<=invalid_found ? empty_slot : victim;
            end else if (PREFETCH!=0 && !nb_cached && nb!={BAW{1'b0}}) begin
                busy<=1; req<=1; req_blk<=nb; fill_tag<=nb;
                fill_slot<=invalid_found ? empty_slot : next_victim;
            end
        end
    end
    end endgenerate
endmodule
