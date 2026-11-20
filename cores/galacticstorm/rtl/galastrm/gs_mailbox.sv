// SPDX-License-Identifier: BSD-3-Clause
// MB8421 2KB dual-port mailbox RAM, board lane wiring.
// MAME 0.289 mb8421.h (hap, AJR): zero at power-on, retain on reset.
// Interrupt pins are unconnected in galastrm; both CPUs poll shared bytes.
module gs_mailbox(
    input logic clk, reset,
    input logic main_req, main_write,
    input logic [10:0] main_byte_addr,
    input logic [15:0] main_wdata,
    input logic [1:0] main_be,
    output logic main_ack,
    output wire [15:0] main_rdata,
    input logic sound_req, sound_write,
    input logic [10:0] sound_byte_addr,
    input logic [15:0] sound_wdata,
    input logic sound_uds,
    output logic sound_ack,
    output wire [15:0] sound_rdata
);
    (* ramstyle="M10K, no_rw_check" *) logic [7:0] even_ram[0:1023],odd_ram[0:1023];
    logic [7:0] main_even,main_odd,sound_even,sound_odd;
    logic main_seen,sound_seen,sound_bank;
    integer i;
    initial begin
        for(i=0;i<1024;i=i+1) begin even_ram[i]=0;odd_ram[i]=0;end
    end
    // Each byte bank has two synchronous read/write ports.
    always_ff @(posedge clk) begin
        main_even<=even_ram[main_byte_addr[10:1]];
        main_odd<=odd_ram[main_byte_addr[10:1]];
        if(!reset && main_req && !main_seen && main_write) begin
            if(main_be[1]) even_ram[main_byte_addr[10:1]]<=main_wdata[15:8];
            if(main_be[0]) odd_ram[main_byte_addr[10:1]]<=main_wdata[7:0];
        end
    end
    always_ff @(posedge clk) begin
        sound_even<=even_ram[sound_byte_addr[10:1]];
        sound_odd<=odd_ram[sound_byte_addr[10:1]];
        if(!reset && sound_req && !sound_seen && sound_write && sound_uds) begin
            if(!sound_byte_addr[0]) even_ram[sound_byte_addr[10:1]]<=sound_wdata[15:8];
            else odd_ram[sound_byte_addr[10:1]]<=sound_wdata[15:8];
        end
    end
    always_ff @(posedge clk) begin
        main_ack<=0;sound_ack<=0;
        if(reset) begin main_seen<=0;sound_seen<=0;sound_bank<=0;end
        else begin
            if(!main_req) main_seen<=0;
            else if(!main_seen) begin main_seen<=1;main_ack<=1;end
            if(!sound_req) sound_seen<=0;
            else if(!sound_seen) begin sound_seen<=1;sound_ack<=1;sound_bank<=sound_byte_addr[0];end
        end
    end
    assign main_rdata={main_even,main_odd};
    assign sound_rdata={sound_bank ? sound_odd : sound_even,8'hff};
endmodule
