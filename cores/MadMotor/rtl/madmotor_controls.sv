// MiSTer host controls adapted to Mad Motor's MAME input ports.
module madmotor_controls (
    input  logic        clk_sys,
    input  logic        reset,
    input  logic [31:0] joystick_0,
    input  logic [31:0] joystick_1,
    input  logic [10:0] ps2_key,
    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    output wire [31:0] mapped_joystick_0,mapped_joystick_1,
    output wire  [15:0] controls,
    output wire  [15:0] dips,
    output wire  [2:0]  coins_n,
    output logic       pause_request
);

    // MiSTer joystick bits 0..3 are R/L/D/U; bits 4..7 are buttons,
    // Start and Coin. These key bindings follow the HeavyUnit top-level.
    logic [31:0] key_p1, key_p2;
    logic key_coin1, key_coin2, key_coin3, key_pause;
    logic key_toggle;
    logic pause_held_q;

    wire [31:0] p1 = joystick_0 | key_p1;
    wire [31:0] p2 = joystick_1 | key_p2;
    assign mapped_joystick_0=p1 | (key_coin1?32'h80:32'd0);
    assign mapped_joystick_1=p2 | (key_coin2?32'h80:32'd0);
    wire pause_held = joystick_0[8] | joystick_1[8] | key_pause;

    // MAME P1/P2 ports are active-low and place U,D,L,R in bits 0..3,
    // Button 1/2 in bits 4/5, unused in bit 6, and Start in bit 7.
    assign controls = {
        ~p2[6], 1'b1, ~p2[5], ~p2[4], ~p2[0], ~p2[1], ~p2[2], ~p2[3],
        ~p1[6], 1'b1, ~p1[5], ~p1[4], ~p1[0], ~p1[1], ~p1[2], ~p1[3]
    };

    // MAME SYSTEM has three active-low coin inputs. A third coin slot has no
    // standard MiSTer J1 bit, so it is available from keyboard key 7 only.
    assign coins_n = {
        ~(key_coin3),
        ~(joystick_1[7] | key_coin2),
        ~(joystick_0[7] | key_coin1)
    };

    logic [15:0] dip_latch;
    assign dips = dip_latch;

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            key_p1 <= 32'd0;
            key_p2 <= 32'd0;
            key_coin1 <= 1'b0;
            key_coin2 <= 1'b0;
            key_coin3 <= 1'b0;
            key_pause <= 1'b0;
            key_toggle <= ps2_key[10];
            dip_latch <= 16'h4f7f;
            pause_held_q <= pause_held;
            pause_request <= 1'b0;
        end else begin
            pause_request <= pause_held & ~pause_held_q;
            pause_held_q <= pause_held;

            if (ioctl_download && ioctl_wr && ioctl_index == 16'd254) begin
                // The <switches> block is one byte per address, low byte first.
                if (ioctl_addr == 27'd0) dip_latch[7:0]  <= ioctl_dout;
                if (ioctl_addr == 27'd1) dip_latch[15:8] <= ioctl_dout;
            end

            // hps_io emits {event toggle, pressed, E0, scan code}. Repeated
            // make events are idempotent; break events clear the held key.
            if (ps2_key[10] != key_toggle) begin
                key_toggle <= ps2_key[10];
                case (ps2_key[7:0])
                    8'h75: key_p1[3] <= ps2_key[9]; // P1 Up
                    8'h72: key_p1[2] <= ps2_key[9]; // P1 Down
                    8'h6b: key_p1[1] <= ps2_key[9]; // P1 Left
                    8'h74: key_p1[0] <= ps2_key[9]; // P1 Right
                    8'h1d: key_p2[3] <= ps2_key[9]; // P2 W / Up
                    8'h1b: key_p2[2] <= ps2_key[9]; // P2 S / Down
                    8'h1c: key_p2[1] <= ps2_key[9]; // P2 A / Left
                    8'h23: key_p2[0] <= ps2_key[9]; // P2 D / Right
                    8'h16: key_p1[6] <= ps2_key[9]; // P1 Start / 1
                    8'h1e: key_p2[6] <= ps2_key[9]; // P2 Start / 2
                    8'h2e: key_coin1 <= ps2_key[9]; // Coin 1 / 5
                    8'h36: key_coin2 <= ps2_key[9]; // Coin 2 / 6
                    8'h3d: key_coin3 <= ps2_key[9]; // Coin 3 / 7
                    8'h4d: key_pause <= ps2_key[9]; // Pause / P
                    8'h14: if (ps2_key[8]) key_p2[4] <= ps2_key[9];
                           else           key_p1[4] <= ps2_key[9];
                    8'h11: if (ps2_key[8]) key_p2[5] <= ps2_key[9];
                           else           key_p1[5] <= ps2_key[9];
                    default: begin end
                endcase
            end
        end
    end

endmodule
