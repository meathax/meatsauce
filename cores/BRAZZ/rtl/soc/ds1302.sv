// SPDX-License-Identifier: GPL-3.0-or-later
// DS1302 slave: LSB-first three-wire serial, BCD calendar and battery-backed RAM.
// Datasheet Rev. 3/15 governs behavior where MAME has documented omissions.
module ds1302 (
    input logic clk, initialize, reset,
    input logic ce, serial_clock, io_input,
    output logic io_output, io_enable, io_read,
    input logic second_tick,
    input logic seed_valid, input logic [55:0] seed_bcd,
    input logic restore_valid, input logic [5:0] state_address,
    input logic [7:0] restore_data, output logic [7:0] state_data,
    output logic seconds_written, state_changed
);
    typedef enum logic [1:0] {COMMAND,WRITE,READ,IGNORE} state_t;
    state_t state;
    logic [7:0] registers [0:8];
    logic [7:0] ram [0:30];
    logic [7:0] snapshot [0:7];
    logic [7:0] burst_buffer [0:7];
    logic previous_ce,previous_clock;
    logic [7:0] shift,command,received,single_read;
    logic [2:0] bits;
    logic [4:0] address;
    logic ram_mode,burst,blocked_burst;
    logic [4:0] next_address;
    logic [7:0] second,minute,hour,date,month,year,weekday,month_days;
    logic day_rollover;
    function automatic logic [7:0] binary(input logic [7:0] b);
        return {4'b0,b[7:4]}*8'd10+{4'b0,b[3:0]};
    endfunction
    // Equivalent to BCD(binary(b)+1), including nondecimal input nibbles.
    // The units digit is at most 16, so one decimal carry is sufficient.
    function automatic logic [7:0] increment_bcd(input logic [7:0] b);
        logic [4:0] tens,units;
        tens={1'b0,b[7:4]}; units={1'b0,b[3:0]}+5'd1;
        if(units>=5'd10) begin units=units-5'd10; tens=tens+5'd1; end
        return {tens[3:0],units[3:0]};
    endfunction
    function automatic logic [7:0] sanitize(input logic [4:0] index,input logic [7:0] value);
        case(index)
            1: return value&8'h7f;
            2: return value&8'hbf;
            3: return value&8'h3f;
            4: return value&8'h1f;
            5: return value&8'h07;
            7: return value&8'h80;
            default: return value;
        endcase
    endfunction
    always_comb begin
        received={io_input,shift[7:1]};
        next_address=address== (ram_mode ? 5'd30:5'd7) ? 5'd0:address+5'd1;
        io_enable=ce && state==READ && !serial_clock;
        io_read=io_enable ? io_output : io_input;
        state_data=0;
        if(state_address<9) state_data=registers[state_address];
        else if(state_address<40) state_data=ram[state_address-6'd9];
        second=binary(registers[0]&8'h7f);
        minute=binary(registers[1]);
        hour=binary(registers[2]&8'h3f);
        if(registers[2][7]) hour=binary(registers[2]&8'h1f);
        date=binary(registers[3]);month=binary(registers[4]);year=binary(registers[6]);
        weekday=registers[5];
        case(month)
            4,6,9,11: month_days=30;
            2: month_days=year%4==0 ? 29:28;
            default: month_days=31;
        endcase
        day_rollover=second==59 && minute==59 &&
            (registers[2][7] ? (hour==11 && registers[2][5]):hour==23);
    end
    always_ff @(posedge clk) begin
        if(initialize) begin
            state<=COMMAND;previous_ce<=0;previous_clock<=0;
            shift<=0;command<=0;single_read<=0;bits<=0;address<=0;
            ram_mode<=0;burst<=0;blocked_burst<=0;io_output<=0;
            seconds_written<=0;state_changed<=0;
            for(int i=0;i<9;i++) registers[i]<=0;
            registers[3]<=8'h01;registers[4]<=8'h01;registers[5]<=8'h07;
            for(int i=0;i<31;i++) ram[i]<=0;
            for(int i=0;i<8;i++) begin snapshot[i]<=0;burst_buffer[i]<=0;end
        end else begin
            previous_ce<=ce;previous_clock<=serial_clock;
            seconds_written<=0;state_changed<=0;
            if(second_tick && !registers[0][7]) begin
                state_changed<=1;
                registers[0]<=second==59 ? 8'd0:increment_bcd(registers[0]&8'h7f);
                if(second==59) begin
                    registers[1]<=minute==59 ? 8'd0:increment_bcd(registers[1]);
                    if(minute==59) begin
                        if(registers[2][7]) begin
                            if(hour==11) registers[2]<=8'h80|{2'b0,~registers[2][5],5'b0}|8'h12;
                            else if(hour==12) registers[2]<=8'h80|{2'b0,registers[2][5],5'b0}|8'h01;
                            else registers[2]<=8'h80|{2'b0,registers[2][5],5'b0}|increment_bcd(registers[2]&8'h1f);
                        end else registers[2]<=hour==23 ? 8'd0:increment_bcd(registers[2]&8'h3f);
                    end
                end
                if(day_rollover) begin
                    registers[5]<=weekday==7 ? 8'd1:8'(weekday+1);
                    if(date>=month_days) begin
                        registers[3]<=8'h01;
                        registers[4]<=month==12 ? 8'h01:increment_bcd(registers[4]);
                        if(month==12) registers[6]<=year==99 ? 8'd0:increment_bcd(registers[6]);
                    end else registers[3]<=increment_bcd(registers[3]);
                end
            end
            if(reset || !ce) begin
                state<=COMMAND;bits<=0;shift<=0;command<=0;io_output<=0;
                if(reset) begin previous_ce<=0;previous_clock<=0;end
            end else if(!previous_ce) begin
                state<=COMMAND;bits<=0;shift<=0;
            end else if(!previous_clock && serial_clock) begin
                if(state==COMMAND) begin
                    shift<=received;
                    if(bits==7) begin
                        command<=received;ram_mode<=received[6];burst<=received[5:1]==31;
                        address<=received[5:1]==31 ? 5'd0:received[5:1];bits<=0;shift<=0;
                        blocked_burst<=registers[7][7];
                        if(!received[7]) state<=IGNORE;
                        else if(received[0]) begin
                            state<=READ;
                            for(int i=0;i<8;i++) snapshot[i]<=registers[i];
                            if(received[6]) begin
                                shift<=received[5:1]==31 ? ram[0]:received[5:1]<31 ? ram[received[5:1]]:8'd0;
                                single_read<=received[5:1]==31 ? ram[0]:received[5:1]<31 ? ram[received[5:1]]:8'd0;
                            end else begin
                                shift<=received[5:1]==31 ? registers[0]:received[5:1]<9 ? registers[received[5:1]]:8'd0;
                                single_read<=received[5:1]==31 ? registers[0]:received[5:1]<9 ? registers[received[5:1]]:8'd0;
                            end
                        end else state<=WRITE;
                    end else bits<=bits+3'd1;
                end else if(state==WRITE) begin
                    shift<=received;
                    if(bits==7) begin
                        bits<=0;shift<=0;
                        if(ram_mode) begin
                            if(!registers[7][7] && address<31) begin ram[address]<=received;state_changed<=1;end
                            if(burst && address<30) address<=address+5'd1;
                            else state<=IGNORE;
                        end else if(burst) begin
                            burst_buffer[address[2:0]]<=received;
                            if(address==7) begin
                                if(!blocked_burst) begin
                                    for(int i=0;i<7;i++) registers[i]<=sanitize(5'(i),burst_buffer[i]);
                                    registers[7]<=received&8'h80;seconds_written<=1;state_changed<=1;
                                end
                                state<=IGNORE;
                            end else address<=address+5'd1;
                        end else begin
                            if(address<9 && (!registers[7][7] || address==7)) begin
                                registers[address]<=sanitize(address,received);state_changed<=1;
                                if(address==0) seconds_written<=1;
                            end
                            state<=IGNORE;
                        end
                    end else bits<=bits+3'd1;
                end
            end else if(previous_clock && !serial_clock && state==READ) begin
                io_output<=shift[0];shift<=shift>>1;
                if(bits==7) begin
                    bits<=0;
                    if(burst) begin
                        address<=next_address;
                        shift<=ram_mode ? ram[next_address]:snapshot[next_address[2:0]];
                    end else shift<=single_read;
                end else bits<=bits+3'd1;
            end
            // HPS seed/restore are startup or battery-state operations, accepted only
            // while CE is inactive. Warm serial reset does not erase calendar/RAM.
            if(seed_valid && !ce) begin
                for(int i=0;i<7;i++) registers[i]<=sanitize(5'(i),seed_bcd[i*8 +: 8]);
                seconds_written<=1;state_changed<=1;
            end
            if(restore_valid && !ce) begin
                if(state_address<9) registers[state_address]<=sanitize(5'(state_address),restore_data);
                else if(state_address<40) ram[state_address-6'd9]<=restore_data;
                if(state_address==0) seconds_written<=1;
                state_changed<=1;
            end
        end
    end
endmodule
