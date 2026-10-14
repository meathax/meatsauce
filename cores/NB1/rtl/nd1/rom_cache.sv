//------------------------------------------------------------------------------
// Direct-mapped read-only cache over a program ROM served from SDRAM, after
// the Xenophobe core's rom_icache (see its history: a CPU that fetches every
// word across SDRAM runs materially slower than the board, and that is
// observable). Read-only, so entries never go stale.
//
// CPU side: level request, ack held while the request stands (a level, so a
// CPU sampling DTACK on its own enable cannot miss it). ROM side: the
// docs/rtl-conventions.md request/ack port.
//------------------------------------------------------------------------------
`default_nettype none

module rom_cache #(
    parameter IDX_BITS = 11,                  // lines (words)
    parameter ADDR_HI  = 19                   // word address MSB (bits ADDR_HI:1)
) (
    input  logic                clk,
    input  logic                reset,
    input  logic [ADDR_HI:1]    cpu_addr,
    input  logic                cpu_req,
    output logic [15:0]         cpu_q,
    output logic                cpu_ack,
    output logic [ADDR_HI:1]    rom_addr,
    output logic                rom_req,
    input  logic [15:0]         rom_q,
    input  logic                rom_ack
);
    localparam TAG_BITS = ADDR_HI - IDX_BITS;
    wire [IDX_BITS-1:0] idx = cpu_addr[IDX_BITS:1];
    wire [TAG_BITS-1:0] tag = cpu_addr[ADDR_HI:IDX_BITS+1];

    logic [15:0]       data_ram [(1<<IDX_BITS)];
    logic [TAG_BITS:0] tag_ram  [(1<<IDX_BITS)];      // {valid, tag}
    logic [15:0]       data_q;
    logic [TAG_BITS:0] tag_q;
    always_ff @(posedge clk) begin
        data_q <= data_ram[idx];
        tag_q  <= tag_ram[idx];
    end

    typedef enum logic [2:0] {C_FLUSH, C_IDLE, C_LOOK, C_MISS, C_DONE} st_e;
    st_e st;
    logic [IDX_BITS-1:0] fill_idx;
    logic [TAG_BITS-1:0] fill_tag;
    logic                fill_we;
    logic [15:0]         fill_data;

    // one writer for each array: the flush walk and the miss fill
    always_ff @(posedge clk) begin
        if (st == C_FLUSH) tag_ram[fill_idx] <= '0;
        else if (fill_we) tag_ram[fill_idx] <= {1'b1, fill_tag};
    end
    always_ff @(posedge clk) begin
        if (fill_we) data_ram[fill_idx] <= fill_data;
    end

    always_ff @(posedge clk) begin
        fill_we <= 1'b0;
        if (reset) begin
            st <= C_FLUSH; rom_req <= 1'b0; cpu_ack <= 1'b0; fill_idx <= '0; rom_addr <= '0; cpu_q <= 16'd0; fill_tag <= '0; fill_data <= 16'd0;
        end else begin
            case (st)
            C_FLUSH: begin
                fill_idx <= fill_idx + 1'd1;
                if (&fill_idx) st <= C_IDLE;
            end
            C_IDLE: begin
                cpu_ack <= 1'b0;
                if (cpu_req) begin
                    fill_idx <= idx; fill_tag <= tag; rom_addr <= cpu_addr;
                    st <= C_LOOK;
                end
            end
            C_LOOK: begin
                if (tag_q[TAG_BITS] && tag_q[TAG_BITS-1:0] == fill_tag) begin
                    cpu_q <= data_q; cpu_ack <= 1'b1; st <= C_DONE;
                end else begin
                    rom_req <= 1'b1; st <= C_MISS;
                end
            end
            C_MISS: if (rom_ack) begin
                fill_data <= rom_q; fill_we <= 1'b1;
                cpu_q <= rom_q; cpu_ack <= 1'b1; rom_req <= 1'b0; st <= C_DONE;
            end
            C_DONE: if (!cpu_req) begin cpu_ack <= 1'b0; st <= C_IDLE; end
            default: st <= C_IDLE;
            endcase
        end
    end
endmodule
