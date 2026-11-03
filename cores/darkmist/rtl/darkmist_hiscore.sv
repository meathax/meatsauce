// SPDX-License-Identifier: GPL-3.0-or-later
// Version-14 Hiscores donor adapter, work-RAM offset contract E01D-E0A8.
module darkmist_hiscore #(parameter integer READY_CYCLES=49152000)(
    input wire clk,reset,paused,autosave,OSD_STATUS,
    input wire service_mode,
    input wire ioctl_upload,ioctl_download,ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [15:0] ioctl_index,
    input wire [7:0] data_from_hps,data_from_ram,
    output wire ioctl_upload_req,pause_cpu,hs_access,hs_we,
    output wire [7:0] data_to_hps,hs_data,
    output wire [11:0] hs_addr
);
    wire config_dump=ioctl_download && (ioctl_index==3 || ioctl_index==4);
    // The donor observes downloaded_dump one edge after transfer falls.
    reg [2:0] transfer_tail=0;
    always @(posedge clk) transfer_tail<={transfer_tail[1:0],config_dump};
    // Service diagnostics reuse work RAM. Keep restore pending until a normal
    // reset/boot; never borrow or write the table while service mode is active.
    wire donor_reset=reset || service_mode || config_dump || |transfer_tail;
    // Defer extraction until normal boot has had one active game second.
    // This timer is separate from donor restore's first/last-byte guards.
    localparam integer TIMER_W=$clog2(READY_CYCLES+1);
    reg [TIMER_W-1:0] startup=0;
    wire armed=startup==READY_CYCLES;
    always @(posedge clk)
        if(reset || service_mode) startup<=0;
        else if(!paused && !armed) startup<=startup+1'b1;
    wire reading,writing,configured;
    wire [11:0] ram_address;
    wire ram_write;
    wire in_range=ram_address>=12'h01d && ram_address<=12'h0a8;
    assign hs_access=paused && !donor_reset && in_range && (reading || writing);
    assign hs_we=hs_access && writing && ram_write && !donor_reset;
    assign hs_addr=ram_address;
    hiscore_dm #(.HS_ADDRESSWIDTH(12),.HS_SCOREWIDTH(8),.CFG_LENGTHWIDTH(1))
    controller(
        .clk(clk),.paused(paused),.reset(donor_reset),.autosave(autosave),
        .ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_download(ioctl_download && ioctl_index[15:8]==0),
        .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index[7:0]),
        .OSD_STATUS(OSD_STATUS && armed && !donor_reset),
        .data_from_hps(data_from_hps),.data_from_ram(data_from_ram),
        .ram_address(ram_address),.data_to_hps(data_to_hps),.data_to_ram(hs_data),
        .ram_write(ram_write),.ram_intent_read(reading),.ram_intent_write(writing),
        .pause_cpu(pause_cpu),.configured(configured)
    );
endmodule
