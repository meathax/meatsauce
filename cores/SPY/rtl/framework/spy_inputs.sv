// SPDX-License-Identifier: GPL-3.0-or-later
// MAME KONAMI8_ALT_B21 and the GX857 cabinet wiring diagram.
module spy_inputs (
    input wire clk,reset,input wire [31:0] joystick_0,joystick_1,
    input wire [10:0] ps2_key,input wire [127:0] status,input wire osd_open,
    output wire [7:0] system_in,p1_in,p2_in,dip1,dip2,
    output wire paused
);
    reg old_toggle=0;
    reg [15:0] keys=0;
    reg user_pause=0,old_pause=0;
    wire pause_button=joystick_0[9]|joystick_1[9]|keys[13];
    always @(posedge clk) begin
        old_toggle<=ps2_key[10];old_pause<=pause_button;
        if(reset) begin keys<=0;user_pause<=0;end
        else begin
            if(pause_button&&!old_pause) user_pause<=!user_pause;
            if(old_toggle!=ps2_key[10]) begin
                case(ps2_key[7:0])
                    8'h75:keys[0]<=ps2_key[9];8'h72:keys[1]<=ps2_key[9];
                    8'h6b:keys[2]<=ps2_key[9];8'h74:keys[3]<=ps2_key[9];
                    8'h14:keys[4]<=ps2_key[9];8'h11:keys[5]<=ps2_key[9];
                    8'h16:keys[6]<=ps2_key[9];8'h1e:keys[7]<=ps2_key[9];
                    8'h2e:keys[8]<=ps2_key[9];8'h36:keys[9]<=ps2_key[9];
                    8'h05:keys[10]<=ps2_key[9];8'h06:keys[11]<=ps2_key[9];
                    8'h4d:keys[13]<=ps2_key[9];default:;
                endcase
            end
        end
    end
    // MiSTer joystick: right,left,down,up, actions in J menu order.
    assign p1_in=~{1'b0,joystick_0[4]|keys[4],joystick_0[5]|keys[5],
        joystick_0[0]|keys[3],joystick_0[1]|keys[2],joystick_0[2]|keys[1],
        joystick_0[3]|keys[0],joystick_0[6]|keys[6]};
    assign p2_in=~{1'b0,joystick_1[4],joystick_1[5],joystick_1[0],
        joystick_1[1],joystick_1[2],joystick_1[3],joystick_1[6]|keys[7]};
    wire [7:0] switches=8'hff^{status[55:52],4'b0000};
    assign system_in={switches[7],switches[6]&~keys[11],switches[5:4],1'b1,
        ~(joystick_0[8]|joystick_1[8]|keys[10]),
        ~(joystick_1[7]|keys[9]),~(joystick_0[7]|keys[8])};
    assign dip1=status[31:24]^8'hff;
    assign dip2=status[23:16]^8'h4e;
    assign paused=user_pause|(osd_open&&!status[1]);
endmodule
