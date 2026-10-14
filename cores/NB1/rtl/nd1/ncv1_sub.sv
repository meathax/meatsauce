//------------------------------------------------------------------------------
// ND-1 sub CPU side: the H8/3002 and its address decode (docs/hardware.md §3).
//   000000-07FFFF  program ROM          -> rom port (through the cache)
//   200000-20FFFF  shared RAM           -> shared RAM port B
//   A00000-A07FFF  C352                 -> reg bus (word index = addr/2)
//   C00000         DSW (active low)     -> dsw
//   C00002         P1/P2 (active low)   -> p1p2
//   C00010/30/40   outputs the board ignores
//------------------------------------------------------------------------------
`default_nettype none

module ncv1_sub (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_h8,

    // program ROM (word address)
    output logic [18:1] rom_addr,
    output logic        rom_req,
    input  logic [15:0] rom_q,
    input  logic        rom_ack,

    // shared RAM port
    output logic [15:1] sh_addr,
    output logic        sh_req,
    output logic  [1:0] sh_we,          // [1] high byte (even address), [0] low byte
    output logic [15:0] sh_wdata,
    input  logic [15:0] sh_q,
    input  logic        sh_ack,

    // C352
    output logic        c352_wr,
    output logic        c352_rd,
    output logic  [9:0] c352_addr,
    output logic [15:0] c352_wdata,
    input  logic [15:0] c352_q,

    input  logic [15:0] dsw,
    input  logic [15:0] p1p2,
    input  logic        irq5_n,         // vblank

    output logic        dbg_istart,
    output logic [23:0] dbg_pc,
    output logic        dbg_irq,
    output logic [23:0] dbg_npc,
    output logic        dbg_sleep,
    output logic [23:0] dbg_bus_addr,
    output logic        dbg_bus_rd,
    output logic        dbg_bus_wr,
    output logic        dbg_bus_word,
    output logic [15:0] dbg_bus_wdata,
    output logic [15:0] dbg_bus_rdata,
    output logic        dbg_bus_ack
);
    logic [23:0] a;
    logic        rd, wr, word, ack;
    logic [15:0] wdata, rdata;

    h83002 mcu (
        .clk(clk), .reset(reset), .cen(cen_h8),
        .ext_addr(a), .ext_rd(rd), .ext_wr(wr), .ext_word(word), .ext_wdata(wdata), .ext_rdata(rdata), .ext_ack(ack),
        .irq5_n(irq5_n),
        .dbg_istart(dbg_istart), .dbg_pc(dbg_pc), .dbg_irq(dbg_irq), .dbg_npc(dbg_npc), .dbg_sleep(dbg_sleep),
        .dbg_bus_addr(dbg_bus_addr), .dbg_bus_rd(dbg_bus_rd), .dbg_bus_wr(dbg_bus_wr), .dbg_bus_word(dbg_bus_word),
        .dbg_bus_wdata(dbg_bus_wdata), .dbg_bus_rdata(dbg_bus_rdata), .dbg_bus_ack(dbg_bus_ack)
    );

    wire req     = rd | wr;
    wire sel_rom = (a[23:19] == 5'b00000);
    wire sel_sh  = (a[23:16] == 8'h20);
    wire sel_c   = (a[23:15] == 9'b1010_0000_0);          // A00000-A07FFF
    wire sel_in  = (a[23:8]  == 16'hc000);
    wire sel_oth = ~(sel_rom | sel_sh | sel_c | sel_in);

    // ROM: read only, word port; a byte read takes the lane
    assign rom_addr = a[18:1];
    assign rom_req  = rd & sel_rom;

    // shared RAM
    assign sh_addr  = a[15:1];
    // the decode is registered (the address compare into the RAM's write enable was the
    // tightest per-clock path): the request reaches the RAM a clock later, still inside the
    // access's first state, and drops with the CPU's request
    logic sh_sel_r;
    always_ff @(posedge clk) sh_sel_r <= ~reset & req & sel_sh;
    assign sh_req   = req & sh_sel_r;
    assign sh_we    = wr ? (word ? 2'b11 : (a[0] ? 2'b01 : 2'b10)) : 2'b00;
    assign sh_wdata = wdata;

    // C352: the strobe, address and data reach the chip through a register (the
    // chip's register file is wide and the H8's decode is not short); read data is
    // valid the clock after that, so the ack comes two clocks after the request
    // rises. One access per request however long it stands; the H8 core samples
    // the ack on its enable, at least five clocks later, so the extra clock is not
    // visible to it.
    logic c_busy, c_p1, c_pulse;
    wire  c_first = req & sel_c & ~c_busy;
    always_ff @(posedge clk) begin
        if (reset) begin
            c_busy <= 1'b0; c_p1 <= 1'b0; c_pulse <= 1'b0;
            c352_wr <= 1'b0; c352_rd <= 1'b0; c352_addr <= 10'd0; c352_wdata <= 16'd0;
        end else begin
            c_p1 <= c_first;
            c_pulse <= c_p1;
            if (c_first) c_busy <= 1'b1; else if (!req) c_busy <= 1'b0;
            c352_wr <= c_first & wr;
            c352_rd <= c_first & rd;
            if (c_first) begin c352_addr <= a[10:1]; c352_wdata <= wdata; end
        end
    end

    // inputs and everything else: acked the clock after the request rises, once
    logic o_busy, o_pulse;
    wire  o_go = req & (sel_in | sel_oth) & ~o_busy;
    always_ff @(posedge clk) begin
        if (reset) begin o_busy <= 1'b0; o_pulse <= 1'b0; end
        else begin
            o_pulse <= o_go;
            if (o_go) o_busy <= 1'b1; else if (!req) o_busy <= 1'b0;
        end
    end

    logic [15:0] in_q;
    always_comb begin
        case (a[7:0])
        8'h00, 8'h01: in_q = dsw;
        8'h02, 8'h03: in_q = p1p2;
        default:      in_q = 16'h0000;
        endcase
    end

    always_comb begin
        ack   = 1'b0; rdata = 16'h0000;
        if (sel_rom)     begin ack = rom_ack; rdata = rom_q; end
        else if (sel_sh) begin ack = sh_ack;  rdata = sh_q; end
        else if (sel_c)  begin ack = c_pulse; rdata = c352_q; end
        else if (sel_in) begin ack = o_pulse; rdata = in_q; end
        else             begin ack = o_pulse; rdata = 16'h0000; end
    end
endmodule
