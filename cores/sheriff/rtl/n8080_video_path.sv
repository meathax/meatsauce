// SPDX-License-Identifier: GPL-3.0-or-later
// Connected related-Bandido 1L/1K/2K/5T/5B functional video path.
// Caller supplies the common counter clock CE and pre-edge 4I levels.
// Address/blanking origins, DRAM-valid timing and exact Sheriff revision
// remain integration requirements; this module does not invent a load offset.
module n8080_video_path (
    input  wire       clk,
    input  wire       ce_counter,
    input  wire       clear_n,
    input  wire [2:0] phase_4i,
    input  wire       hb,
    input  wire       vb,
    input  wire       flip_latched,
    input  wire       serial_right,
    input  wire       serial_left,
    input  wire [7:0] rd,
    output wire       video_bit,
    output wire       load_mode,
    output wire [7:0] register_q
);
    // HB/VB are the high-blank test-point Q outputs. 5T instead receives
    // complementary 4G Qbar6/Qbar8, high during the active intervals.
    // Bandido I/O sheet33: OUT6 D5 -> 2D Q15 -> 2L13/12 -> NOR.
    // Two further inverters (2L11/10 and 2L9/8) provide buffered RV.
    // This is related-board connectivity; exact Sheriff revision is unproven.
    wire nor_direction = !flip_latched;
    wire rev_direction = flip_latched;
    wire load_n = !(!hb && !vb && (&phase_4i));
    wire s0 = !(nor_direction && load_n);
    wire s1 = !(rev_direction && load_n);
    wire [7:0] parallel_pins;
    genvar pin;
    generate for(pin=0;pin<8;pin=pin+1) begin : board_pin_order
        // 1L A=RD7, B=RD6 ... H=RD0.
        assign parallel_pins[pin]=rd[7-pin];
    end endgenerate
    wire qa,qh;
    assign load_mode = s0 && s1;
    n8080_video_register serializer (
        .clk(clk),.ce_clock(ce_counter),.clear_n(clear_n),.s0(s0),.s1(s1),
        .serial_right(serial_right),.serial_left(serial_left),
        .parallel_data(parallel_pins),.q(register_q),.qa(qa),.qh(qh)
    );
    // NAND( NAND(QA,NOR), NAND(QH,REV) ).
    assign video_bit=(qa && nor_direction)||(qh && rev_direction);
endmodule
