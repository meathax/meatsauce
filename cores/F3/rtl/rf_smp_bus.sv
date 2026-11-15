//============================================================================
//  Sample line fetch: 8 consecutive Ensoniq sample bytes from SDRAM.
//
//  rf_gfx_bus with one plane: a request is a level held until the ram
//  domain's completion toggle comes back through a three-flop chain (the
//  CDC reasoning is in rf_gfx_bus), one 4-word burst = 8 bytes = 8 samples.
//  The region: the MRA streams the two Ensoniq ROMs plain at byte
//  0x780000, and the ES5505's word address i is byte i of that (ROADMAP
//  Phase 3), so line {bank, addr[19:3]} is SDRAM bytes 0x780000 +
//  {bank, addr[19:3], 3'b000}, word address 0x3C0000 + {bank, addr[19:3], 2'b00}.
//  THREE bank bits since Puzzle Bobble 3/4: their ensoniq region is 16 MB in
//  MAME, so the otisbank mask is 7 rather than Ray Force's 3, and the sample
//  space is 8 MB rather than 4. Ensoniq is the LAST region in the map, so
//  growing it moves nothing else; a game with a 2-bit mask never generates an
//  address above 4 MB and its half of the map is byte-for-byte unchanged.
//============================================================================

module rf_smp_bus #(parameter SEPARATE_INIT=0)
(
    input  logic        clk_cpu,
    input wire init,
    input  logic        reset,

    input  logic [22:3] addr,          // {bank[2:0], sample address[19:3]}
    input  logic        req,           // one-cycle pulse
    output logic [63:0] line,          // byte k in [8k +: 8]
    output logic        valid,         // one-cycle pulse
    output logic        busy,

    input  logic        clk_ram,
    output logic [26:1] ch_addr,
    input  logic [63:0] ch_dout,
    output logic        ch_req,
    input  logic        ch_ready,
    // ensoniq region base -- a PORT because the core has two SDRAM map
    // profiles now; see cfg_map in Rayforce.sv
    input  logic [26:1] base
);
    wire cold=SEPARATE_INIT?init:reset;


    /* verilator lint_off PROCASSINIT */
    logic done_t = 1'b0;
    /* verilator lint_on PROCASSINIT */
    logic [63:0] ram_line;
    always_ff @(posedge clk_ram) begin
        if(SEPARATE_INIT && init)begin ram_line<=0;done_t<=0;end
        else if(ch_ready)begin ram_line<=ch_dout;done_t<=~done_t;end
    end

    (* preserve, dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 3" *) logic d_s, d_1, d_2;
    logic d_3;
    always_ff @(posedge clk_cpu) begin
        if(SEPARATE_INIT && init)begin d_s<=0;d_1<=0;d_2<=0;d_3<=0;end
        else begin d_s<=done_t;d_1<=d_s;d_2<=d_1;d_3<=d_2;end
    end
    wire d_edge = d_2 ^ d_3;

    // `req` is a one-cycle pulse and rf_es5505 does not look at `busy`: a
    // request arriving while a fetch, its cooling gap or a cancel is still in
    // progress is held here and issued as soon as the bus is free. Dropping
    // it left the sampler waiting for a line forever (all sound stopped and
    // the next host read froze the sound 68000).
    logic        pend;
    logic [22:3] pend_addr;
    logic cancelled,cooling;logic [1:0] low_gap;
    always_ff @(posedge clk_cpu) begin
        valid <= 1'b0;
        if (req) begin pend <= 1'b1; pend_addr <= addr; end
        if(cold)begin
            cancelled<=0;cooling<=0;low_gap<=0;
            busy   <= 1'b0;
            ch_req <= 1'b0;
            pend   <= 1'b0;
        end else if(reset)begin
            busy<=1;cancelled<=cancelled || ch_req;cooling<=1;low_gap<=2;
            pend<=1'b0;
            if(d_edge)ch_req<=0;
        end else if(SEPARATE_INIT && cancelled)begin
            if(d_edge)ch_req<=0;
            if(!ch_req)begin cancelled<=0;cooling<=1;low_gap<=2;end
        end else if(SEPARATE_INIT && cooling)begin
            if(low_gap==0)begin cooling<=0;busy<=0;end else low_gap<=low_gap-1'b1;
        end else if (!busy) begin
            if (req || pend) begin
                ch_addr <= base + {4'd0, req ? addr : pend_addr, 2'b00};
                ch_req  <= 1'b1;
                busy    <= 1'b1;
                pend    <= 1'b0;
            end
        end else if (d_edge) begin
            ch_req <= 1'b0;
            busy<=SEPARATE_INIT?1'b1:1'b0;
            if(SEPARATE_INIT)begin cooling<=1;low_gap<=2;end
            line<=ram_line;
            valid  <= 1'b1;
        end
    end

endmodule
