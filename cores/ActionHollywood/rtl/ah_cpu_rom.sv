// ah_cpu_rom: ROM read cache + next-line prefetch in front of the SDRAM client port.
//
// Line = 32 bit (4 ROM bytes) = the SDRAM client word.  Direct mapped, 2^IDXB lines,
// a one-entry "last fill" buffer (lb) forwards the line that was just filled so the
// BRAM read-after-write hazard never produces a wrong word.
//
//   line     : CPU line address, byte addr[19:2] (ROM is 1 MB), valid as soon as the
//              CPU address bus is stable (hit flags are qualified with a 1-clk stability check)
//   rd_act   : a ROM read bus cycle is in progress (demand: a miss starts a fetch)
//   pf_trig  : 1-clk pulse when a ROM read cycle completes -> prefetch line+1
//   hit/hdata: line present now (hdata = the 32-bit line)
// Client port as docs/CONTRACTS.md: req level held until ack; ack pulse with data.
module ah_cpu_rom #(
    parameter IDXB = 9
)(
    input             clk,
    input             rst,
    input      [17:0] line,
    input             rd_act,
    input             pf_trig,
    output            hit,
    output     [31:0] hdata,
    output reg        init_done,
    output reg        rom_req,
    output     [22:2] rom_addr,
    input             rom_ack,
    input      [31:0] rom_data
);
localparam CL = 1 << IDXB;
localparam TB = 18 - IDXB;

(* ramstyle = "M10K,no_rw_check" *) reg [31:0] c_data [0:CL-1];
(* ramstyle = "M10K,no_rw_check" *) reg [TB:0] c_tag  [0:CL-1];  // {valid, tag}
(* ramstyle = "M10K,no_rw_check" *) reg [TB:0] c_tagb [0:CL-1];  // second read port copy (prefetch check)

localparam S_IDLE = 3'd0, S_DEM = 3'd1, S_PF0 = 3'd2, S_PF1 = 3'd3, S_PFW = 3'd4;
reg [2:0]  st;
reg [17:0] req_line, pf_line;
reg        pf_pend;
reg [IDXB:0] icnt;

// last-fill buffer
reg        lb_v;
reg [17:0] lb_line;
reg [31:0] lb_data;

assign rom_addr = {3'b000, req_line};

wire fill = ((st == S_DEM) || (st == S_PFW)) && rom_ack;
wire wr_en = !init_done || fill;
wire [IDXB-1:0] wr_idx = init_done ? req_line[IDXB-1:0] : icnt[IDXB-1:0];
wire [TB:0]     wr_tag = init_done ? {1'b1, req_line[17:IDXB]} : {(TB+1){1'b0}};

reg [31:0] rd_data;
reg [TB:0] rd_tag, pf_tag;
reg [17:0] la_q, pfa_q;

always @(posedge clk) begin
    if (wr_en) begin
        c_tag [wr_idx] <= wr_tag;
        c_tagb[wr_idx] <= wr_tag;
        if (init_done) c_data[wr_idx] <= rom_data;
    end
    rd_data <= c_data[line[IDXB-1:0]];
    rd_tag  <= c_tag [line[IDXB-1:0]];
    pf_tag  <= c_tagb[pf_line[IDXB-1:0]];
    la_q    <= line;
    pfa_q   <= pf_line;
end

wire lb_hit   = lb_v && (lb_line == line);
wire bram_hit = (la_q == line) && rd_tag[TB] && (rd_tag[TB-1:0] == line[17:IDXB]);
assign hit    = lb_hit | bram_hit;
assign hdata  = lb_hit ? lb_data : rd_data;
wire stable   = (la_q == line);
wire miss     = rd_act && !hit && stable && init_done;

wire pf_ok    = (pfa_q == pf_line) && pf_tag[TB] && (pf_tag[TB-1:0] == pf_line[17:IDXB]);

always @(posedge clk) begin
    if (rst) begin
        st <= S_IDLE; rom_req <= 1'b0; lb_v <= 1'b0; pf_pend <= 1'b0;
        init_done <= 1'b0; icnt <= 0; req_line <= 18'd0; pf_line <= 18'd0;
        lb_line <= 18'd0; lb_data <= 32'd0;
    end else begin
        if (!init_done) begin
            icnt <= icnt + 1'b1;
            if (&icnt[IDXB-1:0]) init_done <= 1'b1;
        end
        case (st)
        S_IDLE: if (miss) begin
                    req_line <= line; rom_req <= 1'b1; st <= S_DEM;
                end else if (pf_pend) begin
                    pf_pend <= 1'b0; st <= S_PF0;
                end
        S_DEM:  if (rom_ack) begin
                    rom_req <= 1'b0; st <= S_IDLE;
                    lb_v <= 1'b1; lb_line <= req_line; lb_data <= rom_data;
                end
        S_PF0:  st <= S_PF1;
        S_PF1:  if (pfa_q != pf_line) st <= S_PF0;           // address still settling
                else if (pf_ok)       st <= S_IDLE;           // already cached
                else begin
                    req_line <= pf_line; rom_req <= 1'b1; st <= S_PFW;
                end
        S_PFW:  if (rom_ack) begin
                    rom_req <= 1'b0; st <= S_IDLE;
                    lb_v <= 1'b1; lb_line <= req_line; lb_data <= rom_data;
                end
        default: st <= S_IDLE;
        endcase
        // prefetch request: next line after the one the CPU just read (ROM is 2^18 lines)
        if (pf_trig && (line != 18'h3FFFF)) begin
            pf_line <= line + 18'd1;
            pf_pend <= 1'b1;
        end
    end
end
endmodule
