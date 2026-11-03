// SPDX-License-Identifier: GPL-3.0-or-later
// Closed-loop relative dial adapter. Angle inputs are native game angles;
// the wrapper must translate screen compass and observe committed game writes.
module caliber_aim_servo(
    input wire clk, reset, dial_reset, paused, enable, tick_ms, advance,
    input wire stick_active, target_update, load,
    input wire [1:0] load_dial,
    input wire [3:0] target_angle,
    input wire [1:0] speed,
    input wire angle_write,
    input wire [3:0] angle_data,
    input wire decoder_step, decoder_dir,
    output wire [1:0] dial,
    output reg pending = 0,
    output reg [3:0] observed = 0, target = 0
);
    localparam IDLE=0, STEPPING=1, WAIT_ACK=2;
    reg [1:0] state=IDLE;
    reg valid=0, aiming=0, start=0, direction=0, ack_seen=0, done_seen=0;
    reg [3:0] expected=0;
    reg [7:0] age_ms=0, delay_ms=0;
    wire busy, done;
    wire [3:0] cw_distance=target-observed;
    wire turn_positive=cw_distance<=8;
    wire [7:0] step_delay=speed==0 ? 8'd12 : speed==1 ? 8'd40 : 8'd0;
    caliber_quad_steps quad(.clk(clk),.reset(reset | dial_reset),.paused(paused),
        .advance(advance),.start(start),.positive(direction),.load(load),.load_dial(load_dial),
        .decoder_step(decoder_step),.decoder_dir(decoder_dir),
        .dial(dial),.busy(busy),.done(done));
    always @(posedge clk) begin
        start <= 0;
        if(reset || dial_reset) begin
            state<=IDLE; pending<=0; valid<=0; aiming<=0; ack_seen<=0; done_seen<=0;
            observed<=0; target<=0; expected<=0; direction<=0; age_ms<=0; delay_ms<=0;
        end else begin
            if(angle_write) begin observed<=angle_data; valid<=1; end
            if(angle_write && pending && angle_data==expected) ack_seen<=1;
            if(done && state==STEPPING) done_seen<=1;
            if(!paused) begin
                if(tick_ms && delay_ms!=0) delay_ms<=delay_ms-1'b1;
                if(!enable) aiming<=0;
                else if(target_update && stick_active) begin target<=target_angle; aiming<=1; end
                case(state)
                    IDLE: if(enable && aiming && valid && !angle_write && delay_ms==0 && target!=observed) begin
                        direction<=turn_positive;
                        expected<=turn_positive ? observed+1'b1 : observed-1'b1;
                        start<=1; pending<=1; ack_seen<=0; done_seen<=0; age_ms<=0; state<=STEPPING;
                    end
                    STEPPING: if(done || done_seen) begin
                        done_seen<=0;
                        if(ack_seen || (angle_write && angle_data==expected)) begin
                            pending<=0; delay_ms<=step_delay; state<=IDLE;
                        end else begin age_ms<=0; state<=WAIT_ACK; end
                    end
                    WAIT_ACK: if(ack_seen || (angle_write && angle_data==expected)) begin
                        pending<=0; delay_ms<=step_delay; state<=IDLE;
                    end else if(tick_ms) begin
                        if(age_ms==119) begin pending<=0; delay_ms<=250; state<=IDLE; end
                        else age_ms<=age_ms+1'b1;
                    end
                    default: begin state<=IDLE; pending<=0; end
                endcase
            end
        end
    end
endmodule
