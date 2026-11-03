// SPY YM3812 timer/status boundary, qualified against pinned MAME 0.289 ymfm.
// The unchanged JTOPL donor continues to synthesize all audible operators.
module spy_ym_timers #(
    parameter integer MASTER_HZ=48000000,
    parameter integer CRYSTAL_HZ=3579545
)(
    input wire clk,reset,pause,cen,write,addr,
    input wire [7:0] data,
    output wire [7:0] status,
    output wire irq_n
);
    reg [7:0] reg_addr,value_a,value_b;
    reg running_a,running_b,flag_a,flag_b,mask_a,mask_b;
    reg [16:0] left_a;
    reg [18:0] left_b;
    reg [25:0] fraction_a,fraction_b;
    reg [6:0] crystal72;
    reg [3:0] fm_phase;
    wire [26:0] sum_a={1'b0,fraction_a}+CRYSTAL_HZ;
    wire [26:0] sum_b={1'b0,fraction_b}+CRYSTAL_HZ;
    wire tick_a=sum_a>=MASTER_HZ,tick_b=sum_b>=MASTER_HZ;
    wire [8:0] delta_a=9'd256-{1'b0,value_a};
    wire [8:0] delta_b=9'd256-{1'b0,value_b};
    wire [16:0] period_a={delta_a,8'd0}+{3'b0,delta_a,5'd0};
    wire [18:0] period_b={delta_b,10'd0}+{3'b0,delta_b,7'd0};
    wire [3:0] fm_next=fm_phase+((cen&&crystal72==71)?4'd1:4'd0);
    wire [10:0] first_b_adjust={fm_next,6'd0}+{3'b0,fm_next,3'd0};
    wire visible_a=flag_a&&!mask_a,visible_b=flag_b&&!mask_b;
    assign irq_n=!(visible_a||visible_b);
    assign status=8'h06|{!irq_n,visible_a,visible_b,5'd0};
    always @(posedge clk) begin
        if(reset)begin
            reg_addr<=0;value_a<=0;value_b<=0;
            running_a<=0;running_b<=0;flag_a<=0;flag_b<=0;mask_a<=0;mask_b<=0;
            left_a<=0;left_b<=0;fraction_a<=0;fraction_b<=0;
            crystal72<=0;fm_phase<=0;
        end else if(!pause)begin
            if(cen)begin
                if(crystal72==71)begin crystal72<=0;fm_phase<=fm_next;end
                else crystal72<=crystal72+1'b1;
            end
            // Relative phase begins at enable. Remainders survive automatic
            // reload, preventing repeated rounding of continuous periods.
            if(running_a)begin
                fraction_a<=tick_a?sum_a-MASTER_HZ:sum_a;
                if(tick_a)begin
                    if(left_a==1)begin left_a<=period_a;flag_a<=1;end
                    else left_a<=left_a-1'b1;
                end
            end
            if(running_b)begin
                fraction_b<=tick_b?sum_b-MASTER_HZ:sum_b;
                if(tick_b)begin
                    if(left_b==1)begin left_b<=period_b;flag_b<=1;end
                    else left_b<=left_b-1'b1;
                end
            end
            if(write)begin
                if(!addr)reg_addr<=data;
                else case(reg_addr)
                    8'h02:value_a<=data;
                    8'h03:value_b<=data;
                    8'h04:begin
                        mask_a<=data[6];mask_b<=data[5];
                        if(data[7])begin flag_a<=0;flag_b<=0;end
                        else begin
                            if(data[6])flag_a<=0;
                            if(data[5])flag_b<=0;
                            if(!data[0])running_a<=0;
                            else if(!running_a)begin
                                running_a<=1;left_a<=period_a;fraction_a<=0;
                            end
                            if(!data[1])running_b<=0;
                            else if(!running_b)begin
                                running_b<=1;left_b<=period_b-first_b_adjust;fraction_b<=0;
                            end
                        end
                    end
                    default:;
                endcase
            end
        end
    end
endmodule
