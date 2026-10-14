// Inputs follow MAME 0.289 src/mame/jaleco/argus.cpp:312-446.
// HPS joystick bits: right,left,down,up,action1,action2,start,coin,pause,
// service,test entry. Parent holds test_hold through the requested machine reset.
module argus_controls (
    input logic clk_sys, reset,
    input logic [1:0] game_id,
    input logic [31:0] joystick_0, joystick_1,
    input logic service_button, test_button, test_hold,
    input logic ioctl_download, ioctl_wr,
    input logic [7:0] ioctl_index, ioctl_dout,
    input logic [24:0] ioctl_addr,
    output logic [7:0] system_in, p1_in, p2_in, dip1, dip2,
    output logic pause_button, test_entry_req
);
    logic [1:0] last_game;
    logic last_test;
    wire test_action = (game_id == 2) &&
        (test_button | joystick_0[10] | joystick_1[10]);
    wire service_action = service_button | ((game_id == 2) && (joystick_0[9] | joystick_1[9]));

    always_comb begin
        // No invented functions on source unknown pins.
        system_in = 8'hff;
        p1_in = {2'b11, ~joystick_0[5:0]};
        p2_in = {2'b11, ~joystick_1[5:0]};
        pause_button = joystick_0[8] | joystick_1[8];
        if (game_id != 2'd3) begin
            system_in[0] = ~joystick_0[6];
            system_in[1] = ~joystick_1[6];
            if (game_id == 0) begin
                system_in[7] = ~joystick_0[7]; // Argus Coin 1
                system_in[6] = ~joystick_1[7]; // Argus Coin 2
            end else begin
                system_in[6] = ~joystick_0[7]; // Valtric/Butasan Coin 1
                system_in[7] = ~joystick_1[7];
                // Valtric: wired JAMMA Service credit pin, ROM does not use it.
                // Butasan: Service credit / test mode pin.
                system_in[5] = ~(service_action | ((game_id == 2) & test_hold));
            end
        end else begin
            p1_in = 8'hff;
            p2_in = 8'hff;
        end
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            last_game <= game_id;
            last_test <= 0;
            test_entry_req <= 0;
            dip1 <= (game_id == 2) ? 8'hff : 8'hcf;
            dip2 <= 8'hff;
        end else begin
            last_game <= game_id;
            last_test <= test_action;
            test_entry_req <= test_action & ~last_test & (game_id == 2);
            if (last_game != game_id) begin
                dip1 <= (game_id == 2) ? 8'hff : 8'hcf;
                dip2 <= 8'hff;
            end else if (ioctl_download && ioctl_wr && ioctl_index == 8'd254) begin
                if (ioctl_addr == 0) dip1 <= ioctl_dout;
                if (ioctl_addr == 1) dip2 <= ioctl_dout;
            end
        end
    end
endmodule
