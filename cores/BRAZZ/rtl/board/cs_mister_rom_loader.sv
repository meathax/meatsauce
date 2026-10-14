// SPDX-License-Identifier: GPL-3.0-or-later
// Main_MiSTer index-0 ROM image: the cartridge (cart_banks x 16 MiB, 48 MiB for crysking), then the
// 128 KiB BIOS, which is exactly the DDR3 layout read by cs_ddr_rom_backend (cart 0x30000000, BIOS
// right after the populated banks). cart_banks comes from the MRA board record (0 = legacy 3).
//
// Two delivery modes, both from the same MRA:
//  * Direct DDR3 (fast): <rom ... address="0x30000000">. Main_MiSTer copies the whole
//    image into DDR3 itself (mra_loader.cpp rom_finish -> shmem_put) and only announces
//    the transfer: FIO_FILE_TX enable carries the byte length in ioctl_addr and no
//    ioctl_wr strobes follow. A download with no data bytes whose announced size equals
//    the image size is accepted; the backend line buffer is then flushed with one
//    zero-strobe token so no stale ROM line survives a reload.
//  * Byte stream (fallback for a Main_MiSTer without address support): every byte is
//    packed into 64-bit DDR writes, contiguous from offset 0, as before.
// hps_io and this bridge share clk_sys. The board/cache stay reset until ready.
module cs_mister_rom_loader #(
    parameter logic [26:0] BIOS_BYTES=27'h0020000
)(
    input logic clk, reset,
    input logic [3:0] cart_banks,
    input logic ioctl_download, ioctl_wr,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output logic ioctl_wait, rom_ready, loading, error,
    output logic load_valid,
    input logic load_ready,
    output logic [3:0] load_target,
    output logic [31:0] load_offset,
    output logic [63:0] load_data,
    output logic [7:0] load_be,
    input logic load_done, load_error
);
    wire [2:0] banks=cart_banks==0 ? 3'd3 : (cart_banks>4'd7 ? 3'd7 : cart_banks[2:0]); // 27-bit ioctl_addr: <=7 banks
    wire [26:0] CART_BYTES={banks,24'b0};
    wire [26:0] TOTAL_BYTES=BIOS_BYTES+CART_BYTES;
    typedef enum logic [1:0] {COLLECT,SEND,COMPLETE} state_t;
    state_t state;
    logic previous, ending, streamed, direct, flushing;
    logic [26:0] count, announced;
    logic [63:0] packed_data;
    wire selected=ioctl_download && ioctl_index==0;
    assign load_valid=!reset && state==SEND;
    assign ioctl_wait=!reset && state!=COLLECT;
    assign loading=selected || state!=COLLECT || ending;
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=COLLECT;previous<=0;ending<=0;count<=0;packed_data<=0;
            streamed<=0;direct<=0;flushing<=0;announced<=0;
            rom_ready<=0;error<=0;load_target<=0;load_offset<=0;load_data<=0;load_be<=0;
        end else begin
            previous<=selected;
            if(selected && !previous) begin
                rom_ready<=0;error<=0;ending<=0;count<=0;packed_data<=0;streamed<=0;direct<=0;
            end
            // Latest announced length while no byte has arrived (direct DDR3 mode).
            if(selected && !streamed && !ioctl_wr) announced<=ioctl_addr;
            if(!selected && previous) ending<=1;
            if(state==SEND && load_ready) state<=COMPLETE;
            if(state==COMPLETE && load_done) begin
                state<=COLLECT;
                if(load_error) error<=1;
                if(flushing) begin
                    flushing<=0;
                    if(!error && !load_error) rom_ready<=1;
                end
            end
            if(selected && ioctl_wr && state==COLLECT) begin
                streamed<=1;
                // First byte may accompany download rising. All later bytes
                // must be contiguous: never silently load a shifted ROM.
                if(ioctl_addr!=(previous ? count : 27'd0) || ioctl_addr>=TOTAL_BYTES) error<=1;
                else begin
                    count<=ioctl_addr+1'b1;
                    packed_data[ioctl_addr[2:0]*8+:8]<=ioctl_dout;
                    if(ioctl_addr[2:0]==7) begin
                        load_data<={ioctl_dout,packed_data[55:0]};load_be<=8'hff;
                        load_target<=ioctl_addr<CART_BYTES ? 4'd4 : 4'd0;
                        load_offset<=32'({ioctl_addr[26:3],3'b0})-
                            (ioctl_addr<CART_BYTES ? 32'd0 : 32'(CART_BYTES));
                        state<=SEND;
                    end
                end
            end
            if(ending && !selected && state==COLLECT && !flushing) begin
                ending<=0;
                if(!streamed) begin
                    // Direct DDR3 image: accept only the exact announced image size.
                    if(announced==TOTAL_BYTES && !error) begin
                        direct<=1;flushing<=1;
                        load_target<=4'd4;load_offset<=0;load_data<=0;load_be<=8'h00;
                        state<=SEND;
                    end else begin rom_ready<=0;error<=1;end
                end else if(count==TOTAL_BYTES && !error) rom_ready<=1;
                else begin rom_ready<=0;error<=1;end
            end
        end
    end
endmodule
