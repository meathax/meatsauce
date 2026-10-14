// SPDX-License-Identifier: GPL-3.0-or-later
// PCB input pins, coin edges/counters, cartridge bank and cabinet lamps.
module cs_board_io (
    input logic clk,reset,
    input logic [31:0] p1_p2_n,p3_p4_n,
    input logic [7:0] system_n,dips_n,
    input logic reg_valid,output logic reg_ready,
    input logic [31:0] reg_address,reg_data,
    input logic [3:0] reg_strobe,input logic reg_write,
    output logic reg_rsp_valid,output logic [31:0] reg_rsp_data,output logic reg_rsp_error,
    output logic [2:0] flash_bank,
    output logic [15:0] lamps,
    output logic [1:0] coin_counter_lines,
    output logic [1:0][31:0] coin_counts,
    output logic [31:0] interrupt_events
);
    logic [7:0] previous_system;
    logic [31:0] read_data;
    always_comb begin
        reg_ready=1;
        read_data=32'h0; // write-only bank/lamp words read as unmapped zero (MAME 0.289)
        case(reg_address)
            32'h01200000: read_data=p1_p2_n;
            32'h01200004: read_data=p3_p4_n;
            32'h01200008: read_data={8'hff,system_n,8'hff,dips_n};
            default: ; // bank/lamps are write-only: MAME unmapped read returns 0.
        endcase
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            previous_system<=8'hff;reg_rsp_valid<=0;reg_rsp_data<=0;reg_rsp_error<=0;
            flash_bank<=0;lamps<=0;coin_counter_lines<=0;coin_counts<=0;interrupt_events<=0;
        end else begin
            previous_system<=system_n;
            interrupt_events<=0;
            if(previous_system[4] && !system_n[4]) interrupt_events[12]<=1;
            if(previous_system[5] && !system_n[5]) interrupt_events[19]<=1;
            reg_rsp_valid<=reg_valid;
            reg_rsp_error<=0;
            if(reg_valid) begin
                reg_rsp_data<=read_data;
                if(reg_write) case(reg_address)
                    32'h01200000: if(reg_strobe[0]) begin
                        coin_counter_lines<=reg_data[1:0];
                        for(int i=0;i<2;i++) if(reg_data[i] && !coin_counter_lines[i]) coin_counts[i]<=coin_counts[i]+32'd1;
                    end
                    // MAME banksw_w is a 32-bit handler: any lane write replaces the bank from
                    // lane-positioned data bits 3:1 (a write without lane 0 therefore selects 0).
                    32'h01280000: if(|reg_strobe) flash_bank<=reg_strobe[0] ? reg_data[3:1] : 3'd0;
                    32'h01320000: begin
                        if(reg_strobe[0]) lamps[7:0]<=reg_data[7:0];
                        if(reg_strobe[2]) lamps[15:8]<=reg_data[23:16];
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
