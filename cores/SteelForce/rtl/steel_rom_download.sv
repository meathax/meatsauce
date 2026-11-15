// Serialized byte download bridge. CPU must remain held until image_valid.
// Registered payload remains stable from presentation through acknowledgement.
// SDRAM writes are whole 16-bit words: some MiSTer SDRAM modules do not honour
// DQML/DQMH, so a byte-masked write overwrites the other lane (hardware boot
// failure 2026-10-14: every ROM word read back as {low,low}). Each 32-byte
// aligned source block is buffered and written as 16 words. The scatter map
// keeps both bytes of every storage word inside one such block: tile/plain
// regions pair source offsets 2i/2i+1, the sprite region pairs i+16 (storage
// low byte, ~s[4]=0) with i (storage high byte).
module steel_rom_download #(
    parameter integer IMAGE_BYTES=23'h680000
)(
    input wire clk,reset,mortalr,memory_ready,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [24:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire ioctl_wait,
    output reg memory_write,
    output reg [22:0] memory_addr,
    output reg [15:0] memory_data,
    input wire memory_ack,
    output reg image_valid,download_error,
    output wire active,
    output reg image_mortalr
);
    reg downloading,ending,flushing;
    reg [23:0] accepted_bytes;
    reg [7:0] block[0:31];
    reg [22:0] block_base;
    reg [3:0] flush_index;
    wire primary=ioctl_download && ioctl_index==16'd0;
    wire sprite_block=block_base>=23'h400000 &&
        block_base<(image_mortalr ? 23'h600000 : 23'h500000);
    wire [4:0] low_offset=sprite_block ? {1'b1,flush_index} : {flush_index,1'b0};
    wire [4:0] high_offset=sprite_block ? {1'b0,flush_index} : {flush_index,1'b1};
    wire [22:0] mapped;
    steel_rom_scatter scatter(.mortalr(image_mortalr),.source_addr({block_base[22:5],low_offset}),.storage_addr(mapped));
    assign active=primary || downloading || ending || flushing || memory_write;
    assign ioctl_wait=primary && (!memory_ready || memory_write || flushing || ending);
    always @(posedge clk) begin
        if(reset) begin
            downloading<=0;ending<=0;flushing<=0;accepted_bytes<=0;flush_index<=0;block_base<=0;
            memory_write<=0;memory_addr<=0;memory_data<=0;
            image_valid<=0;download_error<=0;image_mortalr<=0;
        end else begin
            if(memory_write && memory_ack)memory_write<=0;
            if(flushing && !memory_write)begin
                memory_write<=1;memory_addr<=mapped;
                memory_data<={block[high_offset],block[low_offset]};
                flush_index<=flush_index+1'b1;
                if(flush_index==4'd15)flushing<=0;
            end
            if(!downloading && !ending && primary) begin
                downloading<=1;accepted_bytes<=0;download_error<=0;
                image_valid<=0;image_mortalr<=mortalr;
                // HPS announces the transfer before producing its first write.
                if(ioctl_wr)download_error<=1;
            end else if(downloading) begin
                if(mortalr!=image_mortalr)download_error<=1;
                if(ioctl_wr && primary) begin
                    if(memory_write || flushing || !memory_ready || ioctl_addr!=accepted_bytes ||
                        accepted_bytes>=IMAGE_BYTES)download_error<=1;
                    else begin
                        block[ioctl_addr[4:0]]<=ioctl_din;
                        accepted_bytes<=accepted_bytes+1'b1;
                        if(ioctl_addr[4:0]==5'd31)begin
                            flushing<=1;flush_index<=0;block_base<={ioctl_addr[22:5],5'b0};
                        end
                    end
                end
                if(!primary)begin downloading<=0;ending<=1;end
            end
            if(ending && !memory_write && !flushing)begin
                ending<=0;
                image_valid<=!download_error && accepted_bytes==IMAGE_BYTES;
                if(accepted_bytes!=IMAGE_BYTES)download_error<=1;
            end
        end
    end
endmodule
