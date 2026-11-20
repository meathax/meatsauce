// SPDX-License-Identifier: BSD-3-Clause
// Coalesce real CPU EEPROM writes into held HPS saves. The common-parent host
// clock must run at least twice the CPU clock so every source toggle is sampled.
// Changes during a save queue another save; incomplete transfers are retried.
module gs_nv_save(
    input wire cpu_clk,ram_clk,cold_reset,ready,nvram_dirty,osd_open,
    input wire ioctl_upload,input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,output wire upload_req
);
    reg dirty_toggle;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg dirty_s1,dirty_s2;
    reg seen,pending,previous_upload,transferring,previous_osd;
    // gs_nv_image clamps the live combined-image cursor to 0..128.
    reg [7:0] highest_addr;
    wire change=dirty_s2!=seen;
    wire ours=ioctl_upload && ioctl_index==254;
    assign upload_req=pending && ready && !ioctl_upload;
    always @(posedge cpu_clk)begin
        if(nvram_dirty)dirty_toggle<=!dirty_toggle;
        if(cold_reset)dirty_toggle<=0;
    end
    always @(posedge ram_clk)begin
        dirty_s1<=dirty_toggle;dirty_s2<=dirty_s1;seen<=dirty_s2;
        previous_upload<=ioctl_upload;
        previous_osd<=osd_open;
        if(ours && !previous_upload)begin
            pending<=0;transferring<=1;highest_addr<=0;
        end
        if(ours && ioctl_addr[7:0]>highest_addr)highest_addr<=ioctl_addr[7:0];
        if(previous_upload && !ioctl_upload && transferring)begin
            transferring<=0;
            // HPS advances the cursor after reading each word: 64 words ends at 128.
            if(highest_addr!=128)pending<=1;
        end
        // A simultaneous dirty event wins over transfer-start acknowledgement.
        if(change)pending<=1;
        // Flush EEPROM cabinet settings on OSD entry; retain the request while HPS is busy.
        if(osd_open && !previous_osd)pending<=1;
        if(!ready)begin pending<=0;transferring<=0;highest_addr<=0;end
        if(cold_reset)begin
            dirty_s1<=0;dirty_s2<=0;seen<=0;pending<=0;
            previous_upload<=0;transferring<=0;highest_addr<=0;
            previous_osd<=0;
        end
    end
endmodule
