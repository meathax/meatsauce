// 93C46 serial EEPROM (16-bit organisation, 64 words), behaviour per MAME eepromser.cpp.
// Lines are written by the 68000 at 0xC0000E (bit0 CS, bit1 CLK, bit2 DI); DO is read at 0xC00006 bit 7.
module esd16_eeprom #(
    parameter integer CLK_HZ = 98000000
) (
    input        clk,
    input        wr,            // one-clk strobe: cs_i/clk_i/di_i are the new line values
    input        cs_i, clk_i, di_i,
    output reg   do_o,          // data out (high = ready/idle)
    // NVRAM host port (hps_io download/upload of the 128-byte image, word index 0..63)
    input  [5:0] h_addr,
    input        h_wr,          // one-clk strobe: mem[h_addr] <= h_din
    input [15:0] h_din,
    output [15:0] h_dout,
    output reg   wr_evt         // one-clk pulse after the game changed the contents
);
    localparam [2:0] S_RESET=0, S_START=1, S_CMD=2, S_READ=3, S_WDATA=4, S_DONE=5;
    // Match MAME0.289 eeprom.cpp operation completion times at the existing clk_sys rate.
    localparam integer WRITE_CYCLES = (CLK_HZ / 4000) * 7 + (((CLK_HZ % 4000) * 7 + 3999) / 4000);
    localparam integer ERASE_CYCLES = (CLK_HZ / 1000) + ((CLK_HZ % 1000) != 0);
    localparam integer WRITE_ALL_CYCLES = (CLK_HZ / 125) + ((CLK_HZ % 125) != 0);
    localparam integer ERASE_ALL_CYCLES = WRITE_ALL_CYCLES;
    localparam integer BUSY_MAX_CYCLES = WRITE_ALL_CYCLES;
    localparam integer BUSY_WIDTH = $clog2(BUSY_MAX_CYCLES + 1);
    localparam [BUSY_WIDTH-1:0] WRITE_BUSY_RELOAD = BUSY_WIDTH'(WRITE_CYCLES - 1);
    localparam [BUSY_WIDTH-1:0] ERASE_BUSY_RELOAD = BUSY_WIDTH'(ERASE_CYCLES - 1);
    localparam [BUSY_WIDTH-1:0] WRITE_ALL_BUSY_RELOAD = BUSY_WIDTH'(WRITE_ALL_CYCLES - 1);
    localparam [BUSY_WIDTH-1:0] ERASE_ALL_BUSY_RELOAD = BUSY_WIDTH'(ERASE_ALL_CYCLES - 1);
    reg [15:0] mem [0:63];
    reg        chg;
    assign h_dout = mem[h_addr];
    initial begin : init
        integer i;
        for (i = 0; i < 64; i = i + 1) mem[i] = 16'hFFFF;
        do_o = 1'b1;
    end
    reg [2:0]  st = S_RESET;
    reg        cs = 0, ck = 0, di = 0;
    reg [7:0]  accum = 0;
    reg [5:0]  bits = 0;
    reg [4:0]  nbits = 0;
    reg [31:0] sh = 0;
    reg [5:0]  addr = 0;
    reg [1:0]  op = 0;
    reg        locked = 1'b1;
    reg        cs_just_rose = 0;
    // 93Cxx DO is ready/busy-low in selected S_START; other non-read states use pull-up high.
    reg [BUSY_WIDTH-1:0] busy_remaining = 0;
    integer    k;

    task automatic enter(input [2:0] ns);
        begin st = ns; do_o = (ns != S_READ); end
    endtask

    always @(posedge clk) begin
        cs_just_rose <= 1'b0;
        if (busy_remaining != 0) busy_remaining <= busy_remaining - 1'b1;
        chg = 1'b0;
        if (h_wr) mem[h_addr] = h_din;
        if (wr) begin
            // di is sampled with the edges, as in MAME (lines update before events fire)
            di = di_i;
            if (cs_i != cs) begin
                cs = cs_i;
                if (cs) begin
                    cs_just_rose <= 1'b1;
                    if (st == S_RESET) enter(S_START);
                end else begin
                    enter(S_RESET);
                end
            end
            if (clk_i != ck) begin
                ck = clk_i;
                if (ck && cs) begin
                    case (st)
                        S_START: if (di && !cs_just_rose && (busy_remaining == 0)) begin accum = 0; nbits = 0; enter(S_CMD); end
                        S_CMD: begin
                            accum = {accum[6:0], di};
                            nbits = nbits + 1;
                            if (nbits == 8) begin
                                op = accum[7:6]; addr = accum[5:0];
                                case (op)
                                    2'b10: begin sh = 0; bits = 0; enter(S_READ); end          // READ
                                    2'b01: begin sh = 0; nbits = 0; enter(S_WDATA); end         // WRITE
                                    2'b11: begin
                                        if (!locked) begin mem[addr] = 16'hFFFF; chg = 1'b1; busy_remaining <= ERASE_BUSY_RELOAD; end
                                        enter(locked ? S_RESET : S_DONE);
                                    end // ERASE
                                    default: case (accum[5:4])
                                        2'b00: begin locked = 1'b1; enter(S_RESET); end         // EWDS
                                        2'b11: begin locked = 1'b0; enter(S_RESET); end         // EWEN
                                        2'b10: begin
                                            if (!locked) begin for (k=0;k<64;k=k+1) mem[k] = 16'hFFFF; chg = 1'b1; busy_remaining <= ERASE_ALL_BUSY_RELOAD; end
                                            enter(locked ? S_RESET : S_DONE);
                                        end // ERAL
                                        2'b01: begin sh = 0; nbits = 0; enter(S_WDATA); end     // WRAL
                                    endcase
                                endcase
                            end
                        end
                        S_READ: begin
                            if (bits == 0) sh = {mem[addr], 16'h0000};
                            else sh = {sh[30:0], 1'b1};
                            bits = bits + 1;
                            do_o = sh[31];
                        end
                        S_WDATA: begin
                            sh = {sh[30:0], di};
                            nbits = nbits + 1;
                            if (nbits == 16) begin
                                if (locked) enter(S_RESET);
                                else begin
                                    if (op == 2'b01) begin mem[addr] = sh[15:0]; busy_remaining <= WRITE_BUSY_RELOAD; end
                                    else begin for (k=0;k<64;k=k+1) mem[k] = mem[k] & sh[15:0]; busy_remaining <= WRITE_ALL_BUSY_RELOAD; end
                                    chg = 1'b1;
                                    enter(S_DONE);
                                end
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end
        wr_evt <= chg;
        // 93Cxx exposes READY/BUSY through DO while CS is high in S_START.
        // The other non-read states remain tristated/high through the pull-up.
        if (st == S_START) do_o = (busy_remaining == 0);
    end
endmodule
