// SPDX-License-Identifier: GPL-3.0-or-later
// One-byte MRA file index1: 0 Hangzo, 1 Schmeiser Robo. Commit only at file
// close; retain the game hold until a subsequent validated ROM epoch completes.
// reset is platform initialization, NEVER the download-held game reset.
module hangzo_game_profile (
    input wire clk,reset,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_address,
    input wire [7:0] ioctl_data,
    input wire rom_valid,rom_busy,rom_fault,
    output reg game_id,profile_changed,profile_fault,
    output wire game_hold,
    output wire [23:0] work_ram_base,work_ram_last
);
    reg previous_download,file_active,have_byte,malformed,pending_id;
    reg await_image,image_started,saw_invalid;
    wire start_file=ioctl_download && !previous_download;
    wire profile_start=start_file && ioctl_index==16'd1;
    assign game_hold=profile_start || file_active || await_image || profile_fault;
    assign work_ram_base=game_id ? 24'hff0000 : 24'h3f0000;
    assign work_ram_last=game_id ? 24'hff7fff : 24'h3f3fff;
    always @(posedge clk) begin
        if(reset) begin
            previous_download<=0;file_active<=0;have_byte<=0;malformed<=0;
            pending_id<=0;game_id<=0;profile_changed<=0;profile_fault<=0;
            await_image<=0;image_started<=0;saw_invalid<=0;
        end else begin
            previous_download<=ioctl_download;
            profile_changed<=0;
            if(start_file) begin
                file_active<=ioctl_index==16'd1;
                have_byte<=0;malformed<=0;pending_id<=game_id;
                // Accept the earliest legal write, including the start edge.
                if(profile_start && ioctl_wr) begin
                    if(ioctl_address==0 && ioctl_data<=1) begin
                        have_byte<=1;pending_id<=ioctl_data[0];
                    end else malformed<=1;
                end
            end else if(ioctl_download && file_active) begin
                if(ioctl_index!=16'd1) malformed<=1;
                if(ioctl_wr) begin
                    if(ioctl_index!=16'd1 || have_byte || ioctl_address!=0 || ioctl_data>1)
                        malformed<=1;
                    else begin have_byte<=1;pending_id<=ioctl_data[0];end
                end
            end else if(!ioctl_download && previous_download) begin
                if(file_active) begin
                    if(have_byte && !malformed) begin
                        game_id<=pending_id;profile_changed<=1;profile_fault<=0;
                        await_image<=1;image_started<=0;saw_invalid<=0;
                    end else profile_fault<=1;
                end
                file_active<=0;
            end
            // A stale ROM-valid level, a DIP file, or a partial/failed image
            // cannot release the new profile. Require a later index0 start,
            // its invalid epoch, and the loader's drained/full valid result.
            if(await_image && start_file && ioctl_index==16'd0) begin
                image_started<=1;saw_invalid<=0;
            end
            if(await_image && image_started && !rom_valid) saw_invalid<=1;
            if(await_image && image_started && saw_invalid && rom_valid &&
               !rom_busy && !rom_fault && !file_active && !profile_start)
                await_image<=0;
        end
    end
endmodule
