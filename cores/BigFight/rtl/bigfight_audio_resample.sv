// 48-tap / 32-phase band-limited rate conversion, shared stereo coefficient ROM.
// Native sample data must be stable on sample_i. All events use the fabric clock.
module bigfight_audio_resample #(
    parameter WIDTH=16, parameter PERIOD=800, parameter FM=1
) (
    input wire clk, reset,
    input wire fast_i,
    input wire sample_i, output_tick,
    input wire signed [WIDTH-1:0] left_i, right_i,
    output reg signed [WIDTH-1:0] left_o, right_o,
    output reg valid_o
);
    // The MAC reads a frozen 48-sample window from a circular history.
    // Even a sample on EVERY fabric edge cannot overwrite a pending read:
    // tap j is consumed at request+j+1, whereas its slot cannot be reused
    // until at least request+128-j. For j<=47 that leaves >=33 edges.
    // No sample-rate/enable assumption or timing exception is needed.
    reg [5:0] tap;
    reg [6:0] head, snapshot_head;
    reg [5:0] history_count, snapshot_count;
    reg snapshot_bypass;
    reg signed [WIDTH-1:0] snapshot_left, snapshot_right;
    wire [6:0] write_address = head - 7'd1;
    wire [6:0] read_address = snapshot_head + {1'b0,tap};
    // Synchronous M10K output occupies the former xl/xr pipeline stage.
    // Mask/forward decisions travel beside it into xl_delay/xr_delay.
    (* ramstyle="M10K, no_rw_check" *) reg [2*WIDTH-1:0] history[0:127];
    reg [2*WIDTH-1:0] history_data;
    reg history_zero_q,history_forward_q;
    reg [12:0] remainder;
    reg [4:0] phase;
    wire [13:0] advance={1'b0,remainder}+14'd32;
    wire [13:0] native_period=fast_i ? PERIOD/2 : PERIOD;
    reg busy;
    reg [4:0] captured_phase;
    reg [10:0] addr;
    wire signed [17:0] coefficient;
    bigfight_audio_coeffs #(.FM(FM)) rom(.clk(clk),.addr(addr),.data(coefficient));
    // Capture head/count rather than copying 96 words into registers.
    // A coincident new sample is forwarded at tap zero, so the write-edge
    // value is never consumed through the asynchronous MLAB read port.
    reg signed [WIDTH-1:0] xl_delay, xr_delay;
    reg signed [WIDTH+17:0] pl, pr;
    reg signed [39:0] al, ar;
    reg issue, multiply_valid, add_valid;
    reg [2:0] drain;
    function automatic signed [WIDTH-1:0] quantize(input signed [39:0] v);
        reg signed [39:0] rounded;
        begin
            rounded=(v+40'sd32768) >>> 16;
            if(rounded > ((40'sd1 << (WIDTH-1))-1))
                quantize={1'b0,{(WIDTH-1){1'b1}}};
            else if(rounded < -(40'sd1 << (WIDTH-1)))
                quantize={1'b1,{(WIDTH-1){1'b0}}};
            else quantize=rounded[WIDTH-1:0];
        end
    endfunction
    // A coincident recent sample is forwarded; unwritten slots are masked.
    // All other consumed reads precede reuse by >=33 edges. Thus undefined
    // mixed-port collision data is never consumed (no_rw_check contract).
    always @(posedge clk)begin
        if (!reset && sample_i) history[write_address] <= {left_i,right_i};
        if(busy && tap<48)history_data<=history[read_address];
    end
    always @(posedge clk) begin
        if(reset) begin
            remainder<=0;phase<=0;busy<=0;tap<=0;captured_phase<=0;
            addr<=0;xl_delay<=0;xr_delay<=0;history_zero_q<=1;history_forward_q<=0;
            pl<=0;pr<=0;al<=0;ar<=0;issue<=0;multiply_valid<=0;add_valid<=0;
            drain<=0;left_o<=0;right_o<=0;valid_o<=0;
            head<=0;snapshot_head<=0;history_count<=0;snapshot_count<=0;
            snapshot_bypass<=0;snapshot_left<=0;snapshot_right<=0;
        end else begin
            valid_o<=0;
            if(sample_i) begin
                head<=write_address;
                if(history_count<48) history_count<=history_count+1'b1;
                remainder<=0;phase<=0;
            end else if(phase!=31) begin
                if(advance>=native_period) begin remainder<=advance-native_period;phase<=phase+1'b1;end
                else remainder<=advance[12:0];
            end
            if(output_tick && !busy) begin
                busy<=1;tap<=0;drain<=0;al<=0;ar<=0;
                captured_phase<=sample_i ? 5'd0 : phase;
                snapshot_head<=sample_i ? write_address : head;
                snapshot_count<=(sample_i && history_count<48) ? history_count+1'b1 : history_count;
                snapshot_bypass<=sample_i;
                snapshot_left<=left_i;snapshot_right<=right_i;
            end
            issue<=0;multiply_valid<=issue;add_valid<=multiply_valid;
            if(busy) begin
                if(tap<48) begin
                    addr<={tap,captured_phase};
                    history_zero_q<=tap>=snapshot_count;
                    history_forward_q<=tap==0 && snapshot_bypass;
                    tap<=tap+1'b1;issue<=1;
                end else if(drain!=5) drain<=drain+1'b1;
                if(tap==48 && drain==5) begin
                    left_o<=quantize(al);right_o<=quantize(ar);valid_o<=1;busy<=0;
                end
            end
            xl_delay<=history_zero_q ? 0 : history_forward_q ? snapshot_left : history_data[2*WIDTH-1:WIDTH];
            xr_delay<=history_zero_q ? 0 : history_forward_q ? snapshot_right : history_data[WIDTH-1:0];
            pl<=coefficient*xl_delay;pr<=coefficient*xr_delay;
            if(add_valid) begin al<=al+pl;ar<=ar+pr;end
        end
    end
endmodule
