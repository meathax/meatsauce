// SPDX-License-Identifier: GPL-3.0-or-later
// MAME0.289 atarivad.cpp: one-shot timer, reprogram only on changed full word
// or disabled timer. ACK clears level but does not cancel an armed timer.
// screen.cpp time_until_pos wraps target modulo262 and rolls a deadline within
// half a pixel into the next frame. This follows the existing integer /6 CE.
// Cold/coherent init only; logical reset/pause integration is a separate policy.
module thunderjaws_scanline_irq #(
    parameter integer PIXEL_DIVIDER=6
)(
    input wire clk_sys,init_reset,ce_pixel,
    input wire [8:0] hpos,vpos,
    input wire arm_write,
    input wire [15:0] arm_word,previous_word,
    input wire ack_write,
    output reg irq_level,armed,
    output reg [8:0] target
);
    localparam integer AGE_W=$clog2(PIXEL_DIVIDER+2);
    reg [AGE_W-1:0] age;
    reg skip_next_match;
    wire [8:0] next_line=vpos==9'd261 ? 9'd0 : vpos+9'd1;
    wire [8:0] normalized=arm_word[8:0]>=9'd262 ? arm_word[8:0]-9'd262 : arm_word[8:0];
    wire reprogram=arm_write && (arm_word!=previous_word || !armed);
    wire line_event=ce_pixel && hpos==9'd455;
    wire matching=armed && line_event && next_line==target;
    // At a non-CE sampling edge age+1 clocks have elapsed in this pixel.
    // Remaining <=N/2 means MAME's inclusive half-pixel threshold rolls over.
    wire near_next_line=hpos==9'd455 && normalized==next_line && !ce_pixel &&
        age>=PIXEL_DIVIDER/2-1;
    always @(posedge clk_sys)begin
        if(init_reset)begin
            age<=0;skip_next_match<=0;target<=0;armed<=0;irq_level<=0;
        end else begin
            if(ce_pixel)age<=0;
            else if(age<PIXEL_DIVIDER+1)age<=age+1'b1;
            // A committed reprogram cancels the old deadline before matching.
            // Actual same-edge CPU/timer ordering still needs native integration.
            if(reprogram)begin
                target<=normalized;armed<=1;skip_next_match<=near_next_line;
            end else if(matching)begin
                if(skip_next_match)skip_next_match<=0;
                else begin armed<=0;irq_level<=1;end
            end
            if(ack_write)irq_level<=0;
        end
    end
endmodule
