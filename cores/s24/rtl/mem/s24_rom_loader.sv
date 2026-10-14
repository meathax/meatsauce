import s24_pkg::*;

// MRA regions are transferred independently. Index 0 is an 8-byte descriptor
// and is sent last as the atomic boot commit. MiSTer interleave map="01"
// represents the first/even byte in the low host word lane. Boot and ROM-board
// words are byte-swapped here into the big-endian word convention used by
// fx68k. Floppy images and FD1094 keys remain byte-linear.
module s24_rom_loader (
    input  logic        clk,
    input  logic        reset,
    input  logic        mem_ready,
    input  logic        ioctl_download,
    input  logic [7:0]  ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic        ioctl_wait,
    output board_desc_t descriptor,
    output logic        rom_loaded,
    output logic        wr_req,
    output logic [26:1] wr_addr,
    output logic [15:0] wr_data,
    output logic [1:0]  wr_be,
    input  logic        wr_ack,
    output logic        key_wr,
    output logic [11:0] key_word_addr,
    output logic [15:0] key_wdata
);
    logic [7:0] desc [0:7];
    logic busy, descriptor_seen;
    integer i;

    function automatic [26:0] region_base(input [7:0] idx);
        case (idx)
            8'd1: region_base = SDR_BOOT_BASE;
            8'd2: region_base = SDR_ROMBOARD_BASE;
            8'd3: region_base = SDR_FLOPPY_BASE;
            8'd4: region_base = SDR_FDKEY_BASE;
            default: region_base = 0;
        endcase
    endfunction

    assign ioctl_wait = busy | ~mem_ready;
    always_comb begin
        descriptor.has_floppy  = desc[0][0];
        descriptor.has_romboard= desc[0][1];
        descriptor.has_fd1094  = desc[0][2];
        descriptor.has_upd4701 = desc[0][3];
        descriptor.has_adc     = desc[0][4];
        descriptor.golf_io     = desc[0][5];
        descriptor.hotrod_io   = desc[0][6];
        descriptor.mahjong     = desc[0][7];
        descriptor.magic_table = desc[1][3:0];
        descriptor.reserved1   = desc[1][7:4];
        descriptor.track_bytes_lo = desc[2];
        descriptor.track_bytes_hi = desc[3];
        descriptor.input_profile = desc[4];
        descriptor.profile_version = desc[5];
        descriptor.motherboard_revision = desc[6][7:4];
        descriptor.sprite_memory_population = desc[6][3:2];
        descriptor.fdc_timing_profile = desc[6][1:0];
        descriptor.romboard_profile = desc[7][7:6];
        descriptor.analogue_profile = desc[7][5:4];
        descriptor.video_profile = desc[7][3:2];
        descriptor.cpu_profile = desc[7][1:0];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (i=0;i<8;i=i+1) desc[i] <= 0;
            busy <= 0; descriptor_seen <= 0; rom_loaded <= 0;
            wr_req <= 0; wr_addr <= 0; wr_data <= 0; wr_be <= 0;
            key_wr <= 0; key_word_addr <= 0; key_wdata <= 0;
        end else begin
            key_wr <= 1'b0;
            if (wr_ack) begin wr_req <= 0; busy <= 0; end

            if (ioctl_download && ioctl_wr && !busy && mem_ready) begin
                if (ioctl_index == 0) begin
                    if (ioctl_addr < 8) desc[ioctl_addr[2:0]] <= ioctl_dout[7:0];
                    if (ioctl_addr + 1 < 8) desc[ioctl_addr[2:0]+1'b1] <= ioctl_dout[15:8];
                    descriptor_seen <= 1'b1;
                    rom_loaded <= 1'b0;
                end else if ((ioctl_index >= 1 && ioctl_index <= 3) ||
                             ioctl_index == 8) begin
                    wr_req <= 1'b1;
                    busy <= 1'b1;
                    // Index 8 is MiSTer's persistent overlay for the writable
                    // floppy image.  A present .sav is downloaded after the
                    // immutable index-3 disk and replaces it byte-for-byte.
                    wr_addr <= word_address(
                        (ioctl_index == 8 ? SDR_FLOPPY_BASE :
                         region_base(ioctl_index)) + ioctl_addr);
                    wr_data <= (ioctl_index == 3 || ioctl_index == 8) ? ioctl_dout :
                               {ioctl_dout[7:0],ioctl_dout[15:8]};
                    wr_be <= 2'b11;
                end else if (ioctl_index == 4) begin
                    key_wr <= 1'b1;
                    key_word_addr <= ioctl_addr[12:1];
                    key_wdata <= ioctl_dout;
                end
            end

            if (!ioctl_download && descriptor_seen && !busy) begin
                descriptor_seen <= 1'b0;
                rom_loaded <= 1'b1;
            end
        end
    end
endmodule
