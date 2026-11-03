// SPDX-License-Identifier: GPL-3.0-or-later
// Midnight Resistance high-score persistence through JTFRAME's NVRAM file (index 2).
// MAME hiscore.dat (0.289): maincpu 0x1026EA, 80 bytes, ready when byte 0 == 00, the last
// byte == 26 and 0x102710 == 78. The CPU RAM lives in SDRAM, so the 80-byte table is
// mirrored in registers from completed CPU writes and served back on CPU reads. The
// mirror never takes the memory bus, so a CPU pause or halt cannot be disturbed.
//  * HPS download (ioctl_ram && ioctl_wr) fills a separate buffer that survives game reset.
//  * Once per reset epoch, when the game's own initialisation of the table is observed
//    (fresh writes, the ready values and a quiet window), the buffer replaces the mirror in
//    one clock.
//  * Opening the OSD freezes an atomic copy and asks HPS to upload it. Nothing is saved
//    before the table is initialised, or while a loaded file has not yet been restored.
module midres_score_nvram(
    input wire clk, reset,
    // completed CPU write to the score table (one pulse per write cycle)
    input wire wr_commit,
    input wire [5:0] wr_word,          // word index 0..39 from 0x1026EA
    input wire wr_uds, wr_lds,         // active high byte enables
    input wire [15:0] wr_data,
    // CPU read of the same words
    input wire [5:0] rd_word,
    output wire [15:0] rd_data,
    // JTFRAME NVRAM channel
    input wire ioctl_ram, ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_dout,
    output reg [7:0] ioctl_din=0,
    input wire osd_open,
    output reg upload_request=0,
    output wire restored_out
);
    localparam integer BYTES=80, WORDS=40;
    reg [15:0] img [0:WORDS-1];
    reg [15:0] snap [0:WORDS-1];
    reg [7:0] loaded [0:BYTES-1];
    reg [WORDS-1:0] fresh=0;
    reg loaded_valid=0, restored=0, ready_seen=0, wanted=0, osd_last=0;
    reg [1:0] osd_sync=0;
    // Game initialisation writes the table in a tight loop; restore only after the window has
    // been quiet, so a later default write can never overwrite restored scores.
    reg [11:0] quiet=0;
    integer i;
    initial for(i=0;i<WORDS;i=i+1) begin img[i]=0;snap[i]=0;end
    initial for(i=0;i<BYTES;i=i+1) loaded[i]=0;

    assign rd_data=rd_word<WORDS ? img[rd_word] : 16'd0;
    assign restored_out=restored;

    // 0x1026EA (word0 high byte)==00, 0x102739 (word39 low byte)==26, 0x102710 (word19 high)==78
    wire ready_now=fresh[0] && fresh[39] && fresh[19] && quiet==12'hfff &&
                   img[0][15:8]==8'h00 && img[39][7:0]==8'h26 && img[19][15:8]==8'h78;
    wire saveable=ready_seen && (!loaded_valid || restored);
    wire download_write=ioctl_ram && ioctl_wr;

    always @(posedge clk) begin
        osd_sync<={osd_sync[0],osd_open};
        osd_last<=osd_sync[1];
        upload_request<=0;
        ioctl_din<=ioctl_addr[6:0]<BYTES ?
            (ioctl_addr[0] ? snap[ioctl_addr[6:1]][7:0] : snap[ioctl_addr[6:1]][15:8]) : 8'd0;
        // HPS file download: bytes are in memory order (even address = high byte).
        if(download_write && ioctl_addr<BYTES) begin
            loaded[ioctl_addr[6:0]]<=ioctl_dout;
            if(ioctl_addr==0) loaded_valid<=0;
            if(ioctl_addr==BYTES-1) loaded_valid<=1;
        end
        if(reset) begin
            fresh<=0; restored<=0; ready_seen<=0; wanted<=0; quiet<=0;
        end else begin
            if(wr_commit) quiet<=0;
            else if(quiet!=12'hfff) quiet<=quiet+1'b1;
            if(wr_commit && wr_word<WORDS) begin
                if(wr_uds) img[wr_word][15:8]<=wr_data[15:8];
                if(wr_lds) img[wr_word][7:0]<=wr_data[7:0];
                fresh[wr_word]<=1;
            end
            if(ready_now) ready_seen<=1;
            // Restore only after the game's own table initialisation, once per epoch.
            if(ready_now && loaded_valid && !restored && !download_write && !wr_commit) begin
                for(i=0;i<WORDS;i=i+1) img[i]<={loaded[2*i],loaded[2*i+1]};
                restored<=1;
            end
            if(osd_sync[1] && !osd_last) wanted<=1;
            if(wanted && !ioctl_ram) begin
                wanted<=0;
                if(saveable && !wr_commit) begin
                    for(i=0;i<WORDS;i=i+1) snap[i]<=img[i];
                    upload_request<=1;
                end
            end
        end
    end
endmodule
