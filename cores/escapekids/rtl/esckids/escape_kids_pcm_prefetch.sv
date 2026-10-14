module escape_kids_pcm_prefetch_channel(
    input clk, input rst, input enable, input sample, input bsy, input reverse,
    input [20:0] ch_addr, input [20:0] schedule_addr,
    input [20:0] pin_addr, input ch_cs,
    output reg [7:0] ch_data, output reg ch_ok,
    output [20:0] mem_addr, output mem_cs,
    input [7:0] mem_data, input mem_ok,
    output reg warm, output reg underrun
);
reg [18:0] tag [0:4];
reg [31:0] data [0:4];
reg [4:0] valid;
reg active;
reg [2:0] target;
reg [18:0] fill_tag;
reg [1:0] fill_byte;
reg [31:0] fill_word;
reg choose, present, victim_found;
reg [2:0] choose_target;
reg [18:0] choose_tag;
integer i, d;

function [18:0] desired;
    input [2:0] which;
    begin
        case (which)
            0: desired = schedule_addr[20:2];
            1: desired = reverse ? schedule_addr[20:2] - 19'd1 :
                                   schedule_addr[20:2] + 19'd1;
            2: desired = pin_addr[20:2];
            3: desired = pin_addr[20:2] + 19'd1;
            default: desired = pin_addr[20:2] - 19'd1;
        endcase
    end
endfunction

always @* begin
    ch_data = 8'd0;
    ch_ok = 1'b0;
    for (i = 0; i < 5; i = i + 1)
        if (valid[i] && tag[i] == ch_addr[20:2]) begin
            ch_ok = 1'b1;
            case (ch_addr[1:0])
                0: ch_data = data[i][7:0];
                1: ch_data = data[i][15:8];
                2: ch_data = data[i][23:16];
                3: ch_data = data[i][31:24];
            endcase
        end
    warm = enable;
    for (d = 0; d < 5; d = d + 1) begin
        present = 1'b0;
        for (i = 0; i < 5; i = i + 1)
            if (valid[i] && tag[i] == desired(d[2:0])) present = 1'b1;
        if (!present) warm = 1'b0;
    end
    choose = 1'b0;
    choose_target = 3'd0;
    choose_tag = desired(0);
    for (d = 0; d < 5; d = d + 1) begin
        present = active && fill_tag == desired(d[2:0]);
        for (i = 0; i < 5; i = i + 1)
            if (valid[i] && tag[i] == desired(d[2:0])) present = 1'b1;
        if (!choose && enable && !present) begin
            choose = 1'b1;
            choose_tag = desired(d[2:0]);
        end
    end
    victim_found = 1'b0;
    for (i = 0; i < 5; i = i + 1)
        if (!victim_found && !valid[i]) begin
            choose_target = i[2:0];
            victim_found = 1'b1;
        end
    for (i = 0; i < 5; i = i + 1)
        if (!victim_found && tag[i] != desired(0) &&
            tag[i] != desired(1) && tag[i] != desired(2) &&
            tag[i] != desired(3) && tag[i] != desired(4)) begin
            choose_target = i[2:0];
            victim_found = 1'b1;
        end
    if (!victim_found)
        choose = 1'b0;
end

assign mem_addr = {fill_tag,fill_byte};
assign mem_cs = active;
always @(posedge clk) begin
    if (rst || !enable) begin
        valid <= 5'd0;
        active <= 1'b0;
        target <= 3'd0;
        fill_tag <= 19'd0;
        fill_byte <= 2'd0;
        fill_word <= 32'd0;
        underrun <= 1'b0;
    end else begin
        if (sample && bsy && ch_cs && !ch_ok) underrun <= 1'b1;
        if (!active) begin
            if (choose) begin
                active <= 1'b1;
                target <= choose_target;
                fill_tag <= choose_tag;
                fill_byte <= 2'd0;
                valid[choose_target] <= 1'b0;
            end
        end else if (mem_ok) begin
            case (fill_byte)
                0: fill_word[7:0] <= mem_data;
                1: fill_word[15:8] <= mem_data;
                2: fill_word[23:16] <= mem_data;
                3: begin
                    data[target] <= {mem_data,fill_word[23:0]};
                    tag[target] <= fill_tag;
                    valid[target] <= 1'b1;
                    active <= 1'b0;
                end
            endcase
            if (fill_byte != 3) fill_byte <= fill_byte + 1'd1;
        end
    end
end
endmodule

module escape_kids_pcm_prefetch(
    input clk, input rst, input enable,
    input [20:0] ch0_addr, ch1_addr, ch2_addr, ch3_addr,
    input [20:0] ch0_schedule, ch1_schedule, ch2_schedule, ch3_schedule,
    input [20:0] ch0_pin, ch1_pin, ch2_pin, ch3_pin,
    input [3:0] ch_cs, input [3:0] ch_sample, input [3:0] ch_bsy,
    input [3:0] ch_reverse,
    output [7:0] ch0_data, ch1_data, ch2_data, ch3_data,
    output [3:0] ch_ok, output [3:0] warm,
    output [20:0] mem0_addr, mem1_addr, mem2_addr, mem3_addr,
    output [3:0] mem_cs,
    input [7:0] mem0_data, mem1_data, mem2_data, mem3_data,
    input [3:0] mem_ok, output [3:0] underrun
);
escape_kids_pcm_prefetch_channel u_ch0(clk,rst,enable,ch_sample[0],ch_bsy[0],ch_reverse[0],ch0_addr,ch0_schedule,ch0_pin,ch_cs[0],ch0_data,ch_ok[0],mem0_addr,mem_cs[0],mem0_data,mem_ok[0],warm[0],underrun[0]);
escape_kids_pcm_prefetch_channel u_ch1(clk,rst,enable,ch_sample[1],ch_bsy[1],ch_reverse[1],ch1_addr,ch1_schedule,ch1_pin,ch_cs[1],ch1_data,ch_ok[1],mem1_addr,mem_cs[1],mem1_data,mem_ok[1],warm[1],underrun[1]);
escape_kids_pcm_prefetch_channel u_ch2(clk,rst,enable,ch_sample[2],ch_bsy[2],ch_reverse[2],ch2_addr,ch2_schedule,ch2_pin,ch_cs[2],ch2_data,ch_ok[2],mem2_addr,mem_cs[2],mem2_data,mem_ok[2],warm[2],underrun[2]);
escape_kids_pcm_prefetch_channel u_ch3(clk,rst,enable,ch_sample[3],ch_bsy[3],ch_reverse[3],ch3_addr,ch3_schedule,ch3_pin,ch_cs[3],ch3_data,ch_ok[3],mem3_addr,mem_cs[3],mem3_data,mem_ok[3],warm[3],underrun[3]);
endmodule
