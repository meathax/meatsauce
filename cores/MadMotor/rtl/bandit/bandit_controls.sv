// SPDX-License-Identifier: GPL-3.0-or-later
// Host-side Bandit control adapter. frame_tick is a one-cycle clk enable.
// Axis counts follow MAME 0.289 dec0 trackball_ports (X reversed).
// This is a relative-input adapter, not a pin-level uPD4701 implementation.
module bandit_controls (
    input wire clk, reset, pause, frame_tick, analog_mode,
    input wire [31:0] joystick_0, joystick_1,
    input wire [15:0] right_stick_0, right_stick_1,
    input wire vblank,
    input wire bus_read, bus_write,
    input wire [23:0] bus_address,
    input wire [1:0] bus_be,
    output wire [15:0] player_port,
    output wire [7:0] system_port,
    output wire pause_button,
    output reg [7:0] track_data
);
    // Button slots: Fire, Bomb, Start, Coin, Pause, Service.
    assign pause_button=joystick_0[8] | joystick_1[8];
    assign system_port={vblank, ~(joystick_0[9]|joystick_1[9]),
        ~joystick_1[7],~joystick_0[7],~joystick_1[6],~joystick_0[6],2'b11};

    function automatic [7:0] digital_port(input [31:0] joy,input [15:0] stick,input analog_selected);
        reg up,down,left,right;
        begin
            up=joy[3]; down=joy[2]; left=joy[1]; right=joy[0];
            if(!analog_selected) begin
                right=right | ($signed(stick[7:0])>16);
                left=left | ($signed(stick[7:0]) < -16);
                down=down | ($signed(stick[15:8])>16);
                up=up | ($signed(stick[15:8]) < -16);
            end else begin
                up=0; down=0; left=0; right=0;
            end
            digital_port={2'b11,~joy[5],~joy[4],~right,~left,~down,~up};
        end
    endfunction
    assign player_port={digital_port(joystick_1,right_stick_1,analog_mode),
                        digital_port(joystick_0,right_stick_0,analog_mode)};

    // Fixed dead zone; full travel equals the driver's KEYDELTA(24).
    // Digital input takes priority over the stick on each axis. Opposing
    // digital directions cancel, including when the stick is held.
    function automatic signed [8:0] velocity(input [7:0] stick,
                                               input positive,negative);
        integer value,magnitude;
        begin
            value=$signed(stick);
            magnitude=value<0 ? -value : value;
            if(positive || negative)
                velocity=positive==negative ? 0 : positive ? 24 : -24;
            else if(magnitude<=16) velocity=0;
            else begin
                magnitude=((magnitude-16)*24)/111;
                if(magnitude>24) magnitude=24;
                velocity=value<0 ? -magnitude : magnitude;
            end
        end
    endfunction

    wire signed [8:0] step_x0=-velocity(right_stick_0[7:0],joystick_0[0],joystick_0[1]);
    wire signed [8:0] step_y0= velocity(right_stick_0[15:8],joystick_0[2],joystick_0[3]);
    wire signed [8:0] step_x1=-velocity(right_stick_1[7:0],joystick_1[0],joystick_1[1]);
    wire signed [8:0] step_y1= velocity(right_stick_1[15:8],joystick_1[2],joystick_1[3]);
    reg [11:0] count [0:3];
    wire [11:0] step [0:3];
    assign step[0]={{3{step_x0[8]}},step_x0};
    assign step[1]={{3{step_y0[8]}},step_y0};
    assign step[2]={{3{step_x1[8]}},step_x1};
    assign step[3]={{3{step_y1[8]}},step_y1};
    wire [3:0] clear_axis={bus_address==24'h300018,
        bus_address==24'h300010,bus_address==24'h300008,bus_address==24'h300000};
    integer axis;
    always @(posedge clk) begin
        if(reset) begin
            for(axis=0;axis<4;axis=axis+1) count[axis]<=0;
            track_data<=0;
        end else begin
            for(axis=0;axis<4;axis=axis+1) begin
                if(bus_write && bus_be[0] && clear_axis[axis]) count[axis]<=0;
                else if(frame_tick && analog_mode && !pause)
                    count[axis]<=count[axis]+step[axis];
            end
            // MAME's bus helper snapshots on each read. Hold the byte for
            // the whole CPU transfer; do not let a frame tick tear a read.
            if(bus_read && bus_be[0] && bus_address[23:4]==20'h30001)
                track_data<=bus_address[1] ?
                    {4'b0000,count[bus_address[3:2]][11:8]} :
                    count[bus_address[3:2]][7:0];
        end
    end
endmodule
