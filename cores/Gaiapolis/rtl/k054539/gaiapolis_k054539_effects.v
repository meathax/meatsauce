// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
// Konami 054539 two-loop effects engine.
// Physical authority: SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0.
// Qualified: CNTC frame enable, controls224/225, LFO mux shifts, inverted
// offsets/gains, E/F sends, modulo16 feedback, MULB bits31:16, raw RAM bank
// mux, half-rate inhibit and C/A wet serializers. See effects_decode.v.
//
// RECONSTRUCTED POINTER CONTRACT: the public AG116/AF117/PRE timing discards
// CNTC at the capture point. Its literal behavior is not a working delay.
// Here one moving CNTC contribution is combined with the physically selected
// offset/LFO operands. The first (D4=0) head reads a tap then stores the send;
// the second (D4=1) head adds the truncated feedback product to its prior word.
// This functional reconstruction is isolated in head_address below; it is
// not represented as a proven bit-exact replacement for those capture cells.
// The PCB RAM fold preserves bank and word12:0: two8192x16 banks=32KiB.
//
// Coefficients are signed MULB words supplied by the shared ROMB decoder.
// Keep volume/global/pan as separate stages so all three truncations survive.
// The parent's LFO instances supply lfo_a/b and tick on the FREE native frame.
// send_e/f must be E/F SHADOWS, captured at the native output load, not the
// still-growing current voice accumulators. wet_l/r are nominal LOW-PAN loop
// contributions, not a claim that they belong to the C/A serializer banks.
// The parent may consume raw wet_a/b through the fully qualified bank pipeline.
// slot_tick is an actual scheduled-slot advance; a held filter slot does not
// repeat a transaction. frame_tick always advances CNTC, including while cen
// or the scheduled sequencer is held. External RAM has one HOST-clock read
// latency; ram_we is qualified with cen and live memory ownership.
module gaiapolis_k054539_effects #(
    parameter START_SLOT = 288,
    parameter RETIRE_SLOT = 383
) (
    input                   clk,
    input freeze,
    input                   rst,
    input                   cen,
    input                   frame_tick,
    input                   slot_tick,
    input       [8:0]       sample_cnt,
    input                   mem_enable,
    input       [6:0]       mode224,
    input       [5:0]       mode225,
    input       [15:0]      offset_a0,
    input       [15:0]      offset_a1,
    input       [15:0]      offset_b0,
    input       [15:0]      offset_b1,
    input       [7:0]       gain_a,
    input       [7:0]       gain_b,
    input       [7:0]       lfo_a,
    input       [7:0]       lfo_b,
    input signed [15:0]     send_e,
    input signed [15:0]     send_f,
    input signed [15:0]     volume_a,
    input signed [15:0]     global_a,
    input signed [15:0]     pan_al,
    input signed [15:0]     pan_ar,
    input signed [15:0]     volume_b,
    input signed [15:0]     global_b,
    input signed [15:0]     pan_bl,
    input signed [15:0]     pan_br,
    output reg  [14:0]      ram_addr,
    output reg  [7:0]       ram_din,
    output                  ram_we,
    input       [7:0]       ram_dout,
    output reg signed [15:0] wet_a,
    output reg signed [15:0] wet_b,
    output reg signed [15:0] wet_l,
    output reg signed [15:0] wet_r,
    output reg              wet_ready,
    output reg              wet_valid,
    output                  busy,
    output reg              frame_overrun,
    output reg  [14:0]      frame_counter,
    output reg  [14:0]      wet_frame
);

localparam [4:0] IDLE=0, BEGIN_A=1, BEGIN_B=2,
    TAP_LOW_WAIT=3, TAP_LOW_CAPTURE=4, TAP_HIGH_WAIT=5,
    TAP_HIGH_CAPTURE=6, SEND_LOW_WRITE=7, SEND_HIGH_WRITE=8,
    FEEDBACK_BEGIN=9, FEEDBACK_LOW_WAIT=10, FEEDBACK_LOW_CAPTURE=11,
    FEEDBACK_HIGH_WAIT=12, FEEDBACK_HIGH_CAPTURE=13,
    FEEDBACK_LOW_WRITE=14, FEEDBACK_HIGH_WRITE=15, MIX_BEGIN=16,
    VOLUME_A=17, GLOBAL_A=18, PAN_AL=19, PAN_AR=20,
    VOLUME_B=21, GLOBAL_B=22, PAN_BL=23, PAN_BR=24, RETIRE=25;

reg [4:0] state;
reg write_q, loop_b;
reg [6:0] ctrl224;
reg [5:0] ctrl225;
reg [14:0] counter_hold;
reg [15:0] a0,a1,b0,b1;
reg [7:0] ga,gb,la,lb;
reg signed [15:0] se,sf,delay_a,delay_b;
reg signed [15:0] va,gva,pal,par,vb,gvb,pbl,pbr;
reg [15:0] tap_head,feedback_head;
reg [7:0] read_low;
reg [15:0] write_word;
reg signed [15:0] work,global_work;
reg signed [15:0] mul_sample,mul_coefficient;

wire signed [31:0] multiplier = mul_sample * mul_coefficient;
wire signed [15:0] mul_result = multiplier[31:16];
wire [15:0] read_word = {ram_dout,read_low};
wire [15:0] feedback_word = read_word + mul_result;
wire [15:0] selected_send = (loop_b ? ctrl224[4] : ctrl224[0]) ? sf : se;
wire skip_a = ctrl224[2] && !counter_hold[0];
wire skip_b = (ctrl224[6] && !counter_hold[0]) || ctrl224[3];
assign ram_we = write_q && cen && mem_enable && !rst;
assign busy = state != IDLE;

function [15:0] head_address;
    input [14:0] counter;
    input half_rate;
    input [15:0] offset;
    input [7:0] modulation;
    input double_modulation;
    reg [15:0] moving_head;
    reg [15:0] wobble;
    begin
        moving_head = half_rate ? {2'b00,counter[14:1]} : {1'b0,counter};
        wobble = double_modulation ? {7'd0,modulation,1'b0} : {8'd0,modulation};
        head_address = moving_head + offset - wobble;
    end
endfunction

function [14:0] board_address;
    input [15:0] head;
    input bank_b;
    input byte_high;
    reg bank;
    begin
        case(ctrl225[5:4])
            2'd0: bank = head[9];
            2'd1: bank = head[11];
            2'd2: bank = head[13];
            default: bank = head[15];
        endcase
        board_address = {ctrl224[3] ? bank : bank_b, head[12:0], byte_high};
    end
endfunction

// ACCE arithmetic right shift followed by its low-bit carry: ceil(sample/2).
function signed [15:0] accumulator_sample;
    input signed [15:0] sample;
    begin accumulator_sample = {sample[15],sample[15:1]} + sample[0]; end
endfunction

always @* begin
    mul_sample = 16'sd0;
    mul_coefficient = 16'sd0;
    case(state)
        FEEDBACK_HIGH_CAPTURE: begin
            mul_sample = loop_b ? delay_b : delay_a;
            mul_coefficient = {1'b0,loop_b ? gb : ga,7'b0};
        end
        VOLUME_A: begin mul_sample=wet_a; mul_coefficient=va; end
        GLOBAL_A: begin mul_sample=work; mul_coefficient=gva; end
        PAN_AL: begin mul_sample=global_work; mul_coefficient=pal; end
        PAN_AR: begin mul_sample=global_work; mul_coefficient=par; end
        VOLUME_B: begin mul_sample=wet_b; mul_coefficient=vb; end
        GLOBAL_B: begin mul_sample=work; mul_coefficient=gvb; end
        PAN_BL: begin mul_sample=global_work; mul_coefficient=pbl; end
        PAN_BR: begin mul_sample=global_work; mul_coefficient=pbr; end
        default: begin end
    endcase
end

always @(posedge clk) begin
    if (!freeze || rst) begin
    if(rst) begin
        state<=IDLE; write_q<=0; loop_b<=0;
        frame_counter<=0;counter_hold<=0;wet_frame<=0;
        ram_addr<=0;ram_din<=0;read_low<=0;write_word<=0;
        tap_head<=0;feedback_head<=0;
        ctrl224<=0;ctrl225<=0;a0<=0;a1<=0;b0<=0;b1<=0;
        ga<=0;gb<=0;la<=0;lb<=0;se<=0;sf<=0;
        va<=0;gva<=0;pal<=0;par<=0;vb<=0;gvb<=0;pbl<=0;pbr<=0;
        delay_a<=0;delay_b<=0;work<=0;global_work<=0;
        wet_a<=0;wet_b<=0;wet_l<=0;wet_r<=0;
        wet_ready<=0;wet_valid<=0;frame_overrun<=0;
    end else begin
        // CNTC's normal ENT is CYCLERES, not scheduled-slot service.
        if(frame_tick) frame_counter<=frame_counter+15'd1;
        wet_valid<=0;
        if(cen) begin
            if(slot_tick && sample_cnt==START_SLOT && state!=IDLE)
                frame_overrun<=1;
            // CPU RAM override may take ownership at any host edge.
            // Complete words are not made artificially atomic on this bus.
            if(!mem_enable && state>=BEGIN_A && state<=FEEDBACK_HIGH_WRITE) begin
                write_q<=0;
                state<=MIX_BEGIN;
            end else case(state)
                IDLE: begin
                    write_q<=0;
                    if(slot_tick && sample_cnt==START_SLOT) begin
                        counter_hold<=frame_counter;wet_frame<=frame_counter;
                        ctrl224<=mode224;ctrl225<=mode225;
                        a0<=offset_a0;a1<=offset_a1;b0<=offset_b0;b1<=offset_b1;
                        ga<=gain_a;gb<=gain_b;la<=lfo_a;lb<=lfo_b;
                        se<=send_e;sf<=send_f;
                        va<=volume_a;gva<=global_a;pal<=pan_al;par<=pan_ar;
                        vb<=volume_b;gvb<=global_b;pbl<=pan_bl;pbr<=pan_br;
                        wet_ready<=0;
                        state<=BEGIN_A;
                    end
                end
                BEGIN_A,BEGIN_B: begin
                    loop_b<=state==BEGIN_B;
                    if((state==BEGIN_A && skip_a) || (state==BEGIN_B && skip_b))
                        state<=state==BEGIN_A ? BEGIN_B : MIX_BEGIN;
                    else begin
                        tap_head<=state==BEGIN_A ?
                            head_address(counter_hold,ctrl224[2],a1,la,ctrl224[1]) :
                            head_address(counter_hold,ctrl224[6],b1,lb,ctrl224[5]);
                        feedback_head<=state==BEGIN_A ?
                            head_address(counter_hold,ctrl224[2],b0,8'd0,1'b0) :
                            head_address(counter_hold,ctrl224[6],a0,8'd0,1'b0);
                        ram_addr<=board_address(state==BEGIN_A ?
                            head_address(counter_hold,ctrl224[2],a1,la,ctrl224[1]) :
                            head_address(counter_hold,ctrl224[6],b1,lb,ctrl224[5]),state==BEGIN_B,0);
                        state<=TAP_LOW_WAIT;
                    end
                end
                TAP_LOW_WAIT: state<=TAP_LOW_CAPTURE;
                TAP_LOW_CAPTURE: begin
                    read_low<=ram_dout;ram_addr<=board_address(tap_head,loop_b,1);
                    state<=TAP_HIGH_WAIT;
                end
                TAP_HIGH_WAIT: state<=TAP_HIGH_CAPTURE;
                TAP_HIGH_CAPTURE: begin
                    if(loop_b) delay_b<=read_word; else delay_a<=read_word;
                    write_word<=selected_send;
                    ram_addr<=board_address(tap_head,loop_b,0);
                    ram_din<=selected_send[7:0];write_q<=1;
                    state<=SEND_LOW_WRITE;
                end
                SEND_LOW_WRITE: begin
                    ram_addr<=board_address(tap_head,loop_b,1);
                    ram_din<=write_word[15:8];state<=SEND_HIGH_WRITE;
                end
                SEND_HIGH_WRITE: begin write_q<=0;state<=FEEDBACK_BEGIN;end
                FEEDBACK_BEGIN: begin
                    ram_addr<=board_address(feedback_head,loop_b,0);
                    state<=FEEDBACK_LOW_WAIT;
                end
                FEEDBACK_LOW_WAIT: state<=FEEDBACK_LOW_CAPTURE;
                FEEDBACK_LOW_CAPTURE: begin
                    read_low<=ram_dout;ram_addr<=board_address(feedback_head,loop_b,1);
                    state<=FEEDBACK_HIGH_WAIT;
                end
                FEEDBACK_HIGH_WAIT: state<=FEEDBACK_HIGH_CAPTURE;
                FEEDBACK_HIGH_CAPTURE: begin
                    write_word<=feedback_word;
                    ram_addr<=board_address(feedback_head,loop_b,0);
                    ram_din<=feedback_word[7:0];write_q<=1;
                    state<=FEEDBACK_LOW_WRITE;
                end
                FEEDBACK_LOW_WRITE: begin
                    ram_addr<=board_address(feedback_head,loop_b,1);
                    ram_din<=write_word[15:8];state<=FEEDBACK_HIGH_WRITE;
                end
                FEEDBACK_HIGH_WRITE: begin
                    write_q<=0;state<=loop_b ? MIX_BEGIN : BEGIN_B;
                end
                MIX_BEGIN: begin
                    wet_a<=ctrl225[1] ? se : delay_a;
                    wet_b<=ctrl225[0] ? sf : delay_b;
                    wet_l<=0;wet_r<=0;state<=VOLUME_A;
                end
                VOLUME_A: begin work<=mul_result;state<=GLOBAL_A;end
                GLOBAL_A: begin global_work<=mul_result;state<=PAN_AL;end
                PAN_AL: begin wet_l<=accumulator_sample(mul_result);state<=PAN_AR;end
                PAN_AR: begin wet_r<=accumulator_sample(mul_result);state<=VOLUME_B;end
                VOLUME_B: begin work<=mul_result;state<=GLOBAL_B;end
                GLOBAL_B: begin global_work<=mul_result;state<=PAN_BL;end
                PAN_BL: begin wet_l<=wet_l+accumulator_sample(mul_result);state<=PAN_BR;end
                PAN_BR: begin
                    wet_r<=wet_r+accumulator_sample(mul_result);
                    wet_ready<=1;state<=RETIRE;
                end
                RETIRE: if(slot_tick && sample_cnt==RETIRE_SLOT) begin
                    wet_valid<=1;state<=IDLE;
                end
                default: begin state<=IDLE;write_q<=0;end
            endcase
        end
    end

    end
end
endmodule
