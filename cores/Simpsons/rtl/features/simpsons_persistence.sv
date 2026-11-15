// Simpsons persistence: one MiSTer index-2 NVRAM file, EEPROM then score RAM.
// GPL-3.0-or-later; the score engine is JimmyStones/Hiscores_MiSTer v14.
module simpsons_persistence #(parameter PROBE_PERIOD=480000)(
    input wire clk, reset, paused, osd,
    input wire download, upload, wr,
    input wire [7:0] index, din,
    input wire [26:0] address,
    output wire [7:0] dout,
    output reg upload_request=0,
    output wire pause_cpu,
    output wire [12:0] ram_address,
    output wire [7:0] ram_din,
    output wire ram_read, ram_write,
    input wire [7:0] ram_dout,
    input wire eeprom_written, eeprom_ready,
    output wire eeprom_read,
    output reg [6:0] eeprom_address=0,
    input wire [7:0] eeprom_dout
);
    reg [7:0] eeprom_image [0:127];
    reg last_osd=0, last_upload=0, last_download=0, pending_open=0;
    reg table_qualified=0, last_restore=0, snapshot_open=0;
    reg [31:0] probe_wait=0;
    reg eeprom_dirty=0, eeprom_pending=0, save_pending=0, announced=0;
    reg upload_complete=0;
    reg [3:0] state=0;
    reg [5:0] wait_count=0;
    reg start_ok=0, table_ready=0;
    reg engine_osd=0;
    wire hs_pause, hs_read, hs_write, hs_request, configured;
    wire extract_active, restore_active, image_valid;
    wire [12:0] hs_address;
    wire [7:0] hs_dout;
    wire score_download=download && index==2 && address>=128 && address<208;
    wire cfg_download=download && index==3;
    wire snapshot_pause=state>=2 && state<=9;
    assign pause_cpu=hs_pause | snapshot_pause;
    assign ram_read=hs_read | (state>=3 && state<=6);
    assign ram_write=hs_write;
    assign ram_address=(state==3 || state==4) ? 13'h980 :
                       (state==5 || state==6) ? 13'h9cf : hs_address;
    assign eeprom_read=state==7 || state==8;
    assign dout=address<128 ? eeprom_image[address[6:0]] :
                address<208 && image_valid ? hs_dout : 8'd0;

    hiscore #(.HS_ADDRESSWIDTH(13),.HS_SCOREWIDTH(7),.CFG_ADDRESSWIDTH(1),
              .HS_CONFIGINDEX(3),.HS_DUMPINDEX(5)) u_scores(
        .clk(clk),.reset(reset),.paused(paused | pause_cpu),.autosave(1'b1),
        .ioctl_download(cfg_download | score_download),
        .ioctl_upload(upload && index==2),.ioctl_wr(wr),
        .ioctl_addr(index==2 ? address[24:0]-25'd128 : address[24:0]),
        .ioctl_index(index==2 ? 8'd5 : index),.OSD_STATUS(engine_osd),
        .data_from_hps(din),.data_from_ram(ram_dout),
        .data_to_hps(hs_dout),.ioctl_upload_req(hs_request),
        .ram_address(hs_address),.data_to_ram(ram_din),
        .ram_intent_read(hs_read),.ram_intent_write(),.ram_write(hs_write),
        .pause_cpu(hs_pause),.configured(configured),
        .extract_active(extract_active),.restore_active(restore_active),
        .image_valid(image_valid),.invalidate_dump(download && index==2 && !last_download)
    );

    // The EEPROM snapshot borrows its existing BRAM port only while the CPU
    // is stopped and the serial chip has completed any write/erase command.
    // Gameplay resumes before HPS disk IO; subsequent writes stay dirty.
    always @(posedge clk) begin
        last_osd<=osd;
        last_download<=download;
        last_restore<=restore_active;
        if(probe_wait!=0) probe_wait<=probe_wait-1'b1;
        // A successful restore has already qualified the game's default RAM
        // sentinels before writing saved initials and scores over them.
        if(last_restore && !restore_active && image_valid) table_qualified<=1;
        last_upload<=upload && index==2;
        upload_request<=0;
        if(osd && !last_osd && !download) pending_open<=1;
        if(eeprom_written) eeprom_dirty<=1;
        if(hs_request) save_pending<=1;
        // hps_io advances this address AFTER accepting a byte. Address 208
        // proves that byte 207 was read; address 207 alone does not.
        if(upload && index==2 && address>=208) upload_complete<=1;
        if(last_upload && !(upload && index==2)) begin
            announced<=0;
            if(upload_complete) begin
                save_pending<=0;
                eeprom_pending<=0;
            end
            upload_complete<=0;
        end
        case(state)
            0: if(configured && !extract_active && !restore_active && !hs_pause && !hs_read && !hs_write && !upload && !download && !announced &&
                  (pending_open || (!table_qualified && probe_wait==0))) begin
                snapshot_open<=pending_open;
                if(pending_open) pending_open<=0;
                probe_wait<=PROBE_PERIOD;
                state<=1;
            end
            1: if(eeprom_ready) begin state<=2; wait_count<=16; end
            2: if(wait_count==0) begin
                // A final CPU bus cycle can issue an erase just as pause
                // starts. Wait again after the pad before borrowing BRAM.
                if(eeprom_ready) begin state<=3; wait_count<=4; end
            end else wait_count<=wait_count-1'b1;
            3: if(wait_count==0) state<=4; else wait_count<=wait_count-1'b1;
            4: begin start_ok<=ram_dout==8'h42; state<=5; wait_count<=4; end
            5: if(wait_count==0) state<=6; else wait_count<=wait_count-1'b1;
            6: begin
                if(start_ok && ram_dout==0) table_qualified<=1;
                table_ready<=table_qualified || (start_ok && ram_dout==0);
                if(snapshot_open) begin state<=7; wait_count<=4; eeprom_address<=0; end
                else state<=0;
            end
            7: if(wait_count==0) state<=8; else wait_count<=wait_count-1'b1;
            8: begin
                eeprom_image[eeprom_address]<=eeprom_dout;
                if(eeprom_address==127) begin
                    eeprom_pending<=eeprom_pending | eeprom_dirty;
                    eeprom_dirty<=eeprom_written;
                    state<=9;
                end else begin eeprom_address<=eeprom_address+1'b1; state<=7; wait_count<=4; end
            end
            9: begin engine_osd<=table_ready; state<=10; wait_count<=3; end
            10: if(wait_count==0) begin state<=11; engine_osd<=0; end else wait_count<=wait_count-1'b1;
            11: if(!extract_active && !restore_active) begin
                if((save_pending || eeprom_pending) && !announced) begin
                    upload_request<=1;
                    announced<=1;
                end
                state<=0;
            end
            default: state<=0;
        endcase
        // A new configuration cancels an old game's in-flight operation.
        // Game reset preserves the already captured persistent image.
        if(cfg_download) begin
            state<=0; engine_osd<=0; pending_open<=0; announced<=0;
            save_pending<=0; eeprom_pending<=0; eeprom_dirty<=0;
            table_qualified<=0; table_ready<=0; probe_wait<=0; last_restore<=0;
        end else if(reset) begin
            state<=0; engine_osd<=0; pending_open<=0;
            table_qualified<=0; table_ready<=0; probe_wait<=0; last_restore<=0;
        end
    end
endmodule
