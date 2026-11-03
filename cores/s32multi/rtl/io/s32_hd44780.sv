//============================================================================
//  OutRunners cabinet LCD: HD44780-compatible controller fed from 315-5296
//  output port G (one controller per seat / I/O chip).
//
//  Port G wiring, from the game's driver (outrunners-decomp src/system/lcd.c:
//  lcd_write_data_nibble, lcd_write_command_nibble, lcd_send_next_nibble) and
//  MAME segas32.cpp ("Interleaved with the dj and << >> buttons is the data
//  that drives the lcd display"); every LCD line is inverted on the latch:
//    bit 7:4  ~DB7:DB4        bit 3  ~E (E falls when the bit goes 0->1)
//    bit 2    ~RS             bit 1:0  button lamps (not used here)
//  The program starts the display in 8-bit mode (nibbles 3,3,3), switches to
//  4-bit (2), sends 0C (display on), loads eight CGRAM characters (the DJ's
//  face) and then refreshes 16 DDRAM characters from 80 (cursor home) one
//  nibble per timer interrupt, re-running the start sequence every E10
//  VBLANKs.  Behaviour of each instruction follows MAME hd44780.cpp
//  (control_write / data_write / correct_ac); busy timing and reads are not
//  modelled because the game never reads the controller.
//
//  Memory writes are issued as requests into the shared LCD RAM owned by
//  s32_lcd_panel: DDRAM at {1'b0, ac[6:0]}, CGRAM at {2'b10, ac[5:0]}.
//============================================================================

module s32_hd44780 (
    input            clk,
    input            rst,
    input      [7:0] port_g,       // 315-5296 port G output latch

    output reg       wr_req,       // one-cycle write strobe into LCD RAM
    output reg [7:0] wr_addr,
    output reg [7:0] wr_data,
    output reg       disp_on,
    output reg       two_line,
    output reg [6:0] disp_shift
);

reg       e_n_q;          // previous ~E (port bit 3)
reg       dl8;            // 8-bit interface
reg       want_hi;        // next 4-bit strobe is the high nibble
reg [3:0] hi_nib;
reg [6:0] ac;
reg       cg;             // address counter points at CGRAM
reg       inc;            // I/D
reg       shift_en;       // S
reg       clearing;
reg [6:0] clr_addr;
reg       clr_phase;
// A strobe that arrives while a clear is still filling DDRAM waits here.
reg       pend;
reg       pend_rs;
reg [3:0] pend_d;

wire      e_fall = ~e_n_q & port_g[3];
wire      st_rs  = ~port_g[2];
wire [3:0] st_d  = ~port_g[7:4];

function automatic [6:0] ddram_step(input [6:0] a, input up, input two);
    if (two) begin
        if (up) ddram_step = (a == 7'h27) ? 7'h40 : (a == 7'h67) ? 7'h00 : a + 7'd1;
        else    ddram_step = (a == 7'h40) ? 7'h27 : (a == 7'h00) ? 7'h67 : a - 7'd1;
    end
    else begin
        if (up) ddram_step = (a == 7'h4f) ? 7'h00 : a + 7'd1;
        else    ddram_step = (a == 7'h00) ? 7'h4f : a - 7'd1;
    end
endfunction

function automatic [6:0] ddram_fix(input [6:0] a, input two);
    if (two) begin
        if (a > 7'h67)                    ddram_fix = a - 7'h68;
        else if (a > 7'h27 && a < 7'h40)  ddram_fix = a + 7'h18;
        else                              ddram_fix = a;
    end
    else ddram_fix = (a > 7'h4f) ? a - 7'h50 : a;
endfunction

function automatic [6:0] shift_step(input [6:0] s, input up);
    if (up) shift_step = (s == 7'h4f) ? 7'h00 : s + 7'd1;
    else    shift_step = (s == 7'h00) ? 7'h4f : s - 7'd1;
endfunction

always @(posedge clk) begin
    reg       rs;
    reg [7:0] b;
    reg       have;

    wr_req <= 1'b0;
    if (rst) begin
        e_n_q      <= 1'b0;
        dl8        <= 1'b1;
        want_hi    <= 1'b1;
        hi_nib     <= 4'd0;
        ac         <= 7'd0;
        cg         <= 1'b0;
        inc        <= 1'b1;
        shift_en   <= 1'b0;
        disp_on    <= 1'b0;
        two_line   <= 1'b0;
        disp_shift <= 7'd0;
        clearing   <= 1'b0;
        clr_addr   <= 7'd0;
        clr_phase  <= 1'b0;
        pend       <= 1'b0;
        pend_rs    <= 1'b0;
        pend_d     <= 4'd0;
    end
    else begin
        e_n_q <= port_g[3];

        if (e_fall) begin
            pend    <= 1'b1;
            pend_rs <= st_rs;
            pend_d  <= st_d;
        end

        if (clearing) begin
            // One write every other clock: the panel's shared LCD RAM serves
            // each seat on alternate cycles.
            clr_phase <= ~clr_phase;
            if (!clr_phase) begin
                wr_req   <= 1'b1;
                wr_addr  <= {1'b0, clr_addr};
                wr_data  <= 8'h20;
                clr_addr <= clr_addr + 7'd1;
                if (clr_addr == 7'h7f) clearing <= 1'b0;
            end
        end
        else if (pend && !e_fall) begin
            pend <= 1'b0;
            rs   = pend_rs;
            have = 1'b0;
            b    = 8'h00;
            if (dl8) begin
                b    = {pend_d, 4'h0};
                have = 1'b1;
            end
            else if (want_hi) begin
                hi_nib  <= pend_d;
                want_hi <= 1'b0;
            end
            else begin
                b       = {hi_nib, pend_d};
                have    = 1'b1;
                want_hi <= 1'b1;
            end

            if (have && rs) begin
                wr_req  <= 1'b1;
                wr_data <= b;
                if (cg) begin
                    wr_addr <= {2'b10, ac[5:0]};
                    ac      <= {1'b0, inc ? ac[5:0] + 6'd1 : ac[5:0] - 6'd1};
                end
                else begin
                    wr_addr <= {1'b0, ac};
                    ac      <= ddram_step(ac, inc, two_line);
                    if (shift_en) disp_shift <= shift_step(disp_shift, inc);
                end
            end
            else if (have) begin
                if (b[7]) begin
                    cg <= 1'b0;
                    ac <= ddram_fix(b[6:0], two_line);
                end
                else if (b[6]) begin
                    cg <= 1'b1;
                    ac <= {1'b0, b[5:0]};
                end
                else if (b[5]) begin
                    dl8      <= b[4];
                    two_line <= b[3];
                    want_hi  <= 1'b1;
                    if (!cg) ac <= ddram_fix(ac, b[3]);
                end
                else if (b[4]) begin
                    if (b[3]) disp_shift <= shift_step(disp_shift, b[2]);
                    else if (cg) ac <= {1'b0, b[2] ? ac[5:0] + 6'd1 : ac[5:0] - 6'd1};
                    else ac <= ddram_step(ac, b[2], two_line);
                end
                else if (b[3]) begin
                    disp_on <= b[2];
                end
                else if (b[2]) begin
                    inc      <= b[1];
                    shift_en <= b[0];
                end
                else if (b[1]) begin
                    ac         <= 7'd0;
                    cg         <= 1'b0;
                    inc        <= 1'b1;
                    disp_shift <= 7'd0;
                end
                else if (b[0]) begin
                    ac         <= 7'd0;
                    cg         <= 1'b0;
                    inc        <= 1'b1;
                    disp_shift <= 7'd0;
                    clearing   <= 1'b1;
                    clr_addr   <= 7'd0;
                    clr_phase  <= 1'b0;
                end
            end
        end
    end
end

endmodule
