// SSV cabinet-input wiring shared by the MiSTer wrapper and focused tests.
// Joystick bits use MiSTer's J1 ordering; all PCB input ports are active low.
module ssv_input_ports (
    input  logic        clk,
    input  logic        rst,
    // One synchronous pulse at the native raster frame boundary. Keeping the
    // divider here makes rapid fire independent of host polling and CPU CE.
    input  logic        frame_tick,
    input  logic [31:0] joy_p1,
    input  logic [31:0] joy_p2,
    input  logic [3:0]  input_layout,
    input  logic        system_input_mode,
    input  logic [1:0]  extra_input_mode,
    input  logic        rapid_fire_b3_to_b1,
    input  logic        rapid_fire_b1,
    input  logic        rapid_fire_b2,
    input  logic        test_button,
    input  logic        service_button,
    input  logic        coin1_button,
    input  logic        coin2_button,
    output logic [15:0] p1_port,
    output logic [15:0] p2_port,
    output logic [15:0] system_port,
    output logic [15:0] extra_port
);

logic [1:0] rapid_phase;
wire rapid_pressed = (rapid_phase < 2'd2);

always_ff @(posedge clk) begin
    if (rst)
        rapid_phase <= 2'd0;
    else if (frame_tick)
        rapid_phase <= rapid_phase + 2'd1;
end

function automatic logic [15:0] player_port(
    input logic [31:0] joy,
    input logic rapid_enable
);
    logic b1_pressed, b2_pressed;
    begin
        // B3 becomes the rapid-fire trigger only for descriptors that expose
        // this MiSTer convenience mapping. A direct B1/B2 rapid descriptor
        // instead gates that physical button with the same frame phase.
        b1_pressed = (joy[4] && (!rapid_fire_b1 || rapid_pressed)) ||
                     (rapid_enable && joy[6] && rapid_pressed);
        b2_pressed = joy[5] && (!rapid_fire_b2 || rapid_pressed);
        // Start reads bit 11, not bit 12, so the OSD assign-button prompt
        // order (fixed per bit position, see Arcade-SSV.sv:583-593) comes out
        // Coin,Start,Service,Test. Bit 12 is Service's dedicated bit now --
        // it was Start's until 2026-08-19; do not let the two collide again.
        player_port = {8'hff, ~{joy[3], joy[2], joy[1], joy[0],
                                  b1_pressed, b2_pressed,
                                  rapid_enable ? 1'b0 : joy[6], joy[11]}};
    end
endfunction

function automatic logic [15:0] quiz_port(input logic [31:0] joy);
    quiz_port = {8'hff, ~{joy[4], joy[5], joy[6], joy[7],
                            3'b000, joy[12]}};
endfunction

function automatic logic [15:0] six_button_port(
    input logic [31:0] j1,
    input logic [31:0] j2
);
    six_button_port = {8'hff, ~{1'b0, j2[9], j2[8], j2[7],
                                1'b0, j1[9], j1[8], j1[7]}};
endfunction

logic [15:0] system_port_live;

always_comb begin
    p1_port = (input_layout == 4'd2) ? quiz_port(joy_p1)
                                      : player_port(joy_p1, rapid_fire_b3_to_b1);
    p2_port = (input_layout == 4'd2) ? quiz_port(joy_p2)
                                      : player_port(joy_p2, rapid_fire_b3_to_b1);

    system_port_live = {8'hff,
        ~{3'b000, test_button, 1'b0, service_button,
          coin2_button, coin1_button}};
    system_port = system_input_mode ? (system_port_live | 16'h0018)
                                    : system_port_live;

    extra_port = (extra_input_mode == 2'd2)
               ? six_button_port(joy_p1, joy_p2) : 16'hffff;
end

endmodule
