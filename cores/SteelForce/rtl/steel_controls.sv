// MiSTer J1 layout: actions 4..6, Start 10, Coin 11, Pause 12, Service 13.
// Cabinet inputs follow MAME stlforce INPUT/SYSTEM active-low bit order.
module steel_controls(
    input wire clk, reset, osd_status, service_button,
    input wire [31:0] joystick_0, joystick_1,
    output wire [15:0] input_word, system_word,
    output wire pause_cpu
);
    reg pause_key=0, user_pause=0;
    wire pause_now=joystick_0[12] | joystick_1[12];
    always @(posedge clk) begin
        pause_key<=pause_now;
        if(reset) user_pause<=0;
        else if(pause_now && !pause_key) user_pause<=!user_pause;
    end
    assign pause_cpu=user_pause | osd_status;
    assign input_word=~{
        joystick_1[10],joystick_1[6:4],joystick_1[0],joystick_1[1],joystick_1[2],joystick_1[3],
        joystick_0[10],joystick_0[6:4],joystick_0[0],joystick_0[1],joystick_0[2],joystick_0[3]
    };
    // CPU board supplies physical vblank and EEPROM DO on bits 4 and 6.
    assign system_word=16'hffff ^ {12'b0,(service_button | joystick_0[13] | joystick_1[13]),1'b0,joystick_1[11],joystick_0[11]};
endmodule
