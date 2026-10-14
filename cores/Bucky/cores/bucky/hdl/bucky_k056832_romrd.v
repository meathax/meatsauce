/*
 * K056832 tile-ROM CPU readback arbiter.
 *
 * GX173 maps 0x190000-0x191fff to the K056832 ROM passthrough while the
 * visible tile fetcher uses the same 32-bit SDRAM slot.  JTFRAME ROM requests
 * are edge-triggered on chip-select, so a CPU read must first break any tile
 * request, then issue one stable request and hold the result until the 68000
 * bus cycle completes.
 *
 * The JTFRAME 32-bit ROM slot presents an even 16-bit word on scr_data[15:0]
 * and the odd word on scr_data[31:16].  The readback window is a sliding
 * 8KiB slice of the 2MiB tile ROM, selected by rom_bank (K056832 mmr[0x1a],
 * MAME k056832.cpp:685-694); CPU word offset [12:1] maps to the word address
 * within that slice.
 */
module bucky_k056832_romrd(
    input             rst,
    input             clk,

    // CPU-side K056832 ROM passthrough request.
    input             rd_cs,
    input      [12:1] rd_addr,
    input      [ 7:0] rd_bank,
    output            rd_ok,
    output     [15:0] rd_data,

    // Tile fetcher request sharing the SDRAM slot.
    input      [18:0] tile_addr,
    input             tile_cs,
    output            tile_ok,

    // Shared JTFRAME ROM slot.
    output     [18:0] scr_addr,
    output            scr_cs,
    input      [31:0] scr_data,
    input             scr_ok
);

localparam [2:0] S_IDLE  = 3'd0;
localparam [2:0] S_BREAK = 3'd1;
localparam [2:0] S_REQ   = 3'd2;
localparam [2:0] S_WAIT  = 3'd3;
localparam [2:0] S_DONE  = 3'd4;

reg [2:0]  state;
reg [12:1] rd_addr_l;
reg [ 7:0] rd_bank_l;
reg [15:0] rd_data_l;

always @(posedge clk, posedge rst) begin
    if (rst) begin
        state     <= S_IDLE;
        rd_addr_l<= 0;
        rd_bank_l<= 0;
        rd_data_l<= 0;
    end else begin
        case (state)
            S_IDLE: begin
                if (rd_cs) begin
                    rd_addr_l <= rd_addr;
                    rd_bank_l <= rd_bank;
                    state     <= S_BREAK;
                end
            end
            S_BREAK: begin
                if (!rd_cs) state <= S_IDLE;
                else        state <= S_REQ;
            end
            S_REQ: begin
                if (!rd_cs) state <= S_IDLE;
                else        state <= S_WAIT;
            end
            S_WAIT: begin
                if (!rd_cs) begin
                    state <= S_IDLE;
                end else if (scr_ok) begin
                    rd_data_l <= rd_addr_l[1] ? scr_data[31:16] : scr_data[15:0];
                    state     <= S_DONE;
                end
            end
            S_DONE: begin
                if (!rd_cs) state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end

// A newly asserted CPU request wins immediately, including the cycle before
// S_BREAK is clocked.  This guarantees a tile request is dropped for a full
// edge before the CPU request rises at the SDRAM slot.
assign scr_cs   = rd_cs ? ((state == S_REQ) || (state == S_WAIT)) :
                  ((state == S_IDLE) ? tile_cs : 1'b0);
assign scr_addr = (rd_cs && ((state == S_REQ) || (state == S_WAIT))) ?
                  {rd_bank_l,rd_addr_l[12:2]} : tile_addr;
assign rd_ok    = rd_cs && (state == S_DONE);
assign rd_data  = rd_data_l;
assign tile_ok  = !rd_cs && (state == S_IDLE) && scr_ok;

endmodule
