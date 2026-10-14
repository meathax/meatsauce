module escape_kids_voice_mute #(
    parameter [20:0] START_ONE = 21'h734ed,
    parameter [20:0] START_TWO = 21'h6c3b0
)(
    input             clk,
    input             rst,
    input             enable,
    input      [ 3:0] channel_bsy,
    input      [20:0] ch0_start,
    input      [20:0] ch1_start,
    input      [20:0] ch2_start,
    input      [20:0] ch3_start,
    input      [ 3:0] channel_en,
    output     [ 3:0] channel_en_out
);

wire [3:0] start_hit = {
    ch3_start == START_ONE || ch3_start == START_TWO,
    ch2_start == START_ONE || ch2_start == START_TWO,
    ch1_start == START_ONE || ch1_start == START_TWO,
    ch0_start == START_ONE || ch0_start == START_TWO
};

reg [3:0] bsy_l, muted;
wire [3:0] rising_hit = {4{enable}} & channel_bsy & ~bsy_l & start_hit;

assign channel_en_out = channel_en & ~(muted | rising_hit);

always @(posedge clk) begin
    if( rst ) begin
        bsy_l <= 4'd0;
        muted <= 4'd0;
    end else begin
        bsy_l <= channel_bsy;
        if( !enable ) begin
            muted <= 4'd0;
        end else begin
            if( !channel_bsy[0] ) muted[0] <= 1'b0;
            else if( !bsy_l[0] )  muted[0] <= start_hit[0];
            if( !channel_bsy[1] ) muted[1] <= 1'b0;
            else if( !bsy_l[1] )  muted[1] <= start_hit[1];
            if( !channel_bsy[2] ) muted[2] <= 1'b0;
            else if( !bsy_l[2] )  muted[2] <= start_hit[2];
            if( !channel_bsy[3] ) muted[3] <= 1'b0;
            else if( !bsy_l[3] )  muted[3] <= start_hit[3];
        end
    end
end

endmodule
