// SPDX-License-Identifier: GPL-3.0-or-later
// Generate one native four-count dial movement and count actual decoder steps.
// The surrounding controller must wait for the game to acknowledge its angle.
module caliber_quad_steps(
    input wire clk, reset, paused, advance,
    input wire start, positive, load,
    input wire [1:0] load_dial,
    input wire decoder_step, decoder_dir,
    output reg [1:0] dial = 0,
    output reg busy = 0,
    output reg done = 0
);
    reg direction = 0;
    reg [2:0] remaining = 0;
    reg waiting = 0;
    always @(posedge clk) begin
        done <= 0;
        if(reset) begin
            dial <= 0;
            busy <= 0;
            direction <= 0;
            remaining <= 0;
            waiting <= 0;
        end else begin
            // The decoder samples our output one cycle later and registers
            // its step. Count that response even when a pause begins.
            if(busy && decoder_step && decoder_dir == direction) begin
                if(remaining == 1) begin
                    remaining <= 0;
                    busy <= 0;
                    done <= 1;
                end else remaining <= remaining - 1'b1;
            end
            if(waiting) waiting <= 0;
            if(!busy && !paused && load) begin
                dial <= load_dial;
            end else if(!busy && !paused && start) begin
                direction <= positive;
                remaining <= 4;
                busy <= 1;
            end else if(busy && !paused && advance && !waiting && !decoder_step) begin
                if(direction) begin
                    case(dial)
                        2'b00: dial <= 2'b10;
                        2'b10: dial <= 2'b11;
                        2'b11: dial <= 2'b01;
                        2'b01: dial <= 2'b00;
                    endcase
                end else begin
                    case(dial)
                        2'b00: dial <= 2'b01;
                        2'b01: dial <= 2'b11;
                        2'b11: dial <= 2'b10;
                        2'b10: dial <= 2'b00;
                    endcase
                end
                waiting <= 1;
            end
        end
    end
endmodule
