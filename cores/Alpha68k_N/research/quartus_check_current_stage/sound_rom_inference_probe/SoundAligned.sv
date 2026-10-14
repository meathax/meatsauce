// Private scaled inference probe; canonical source is unchanged.
// Parallel word/control registers preserve the legacy post-edge DI value.
module SoundAligned (
    input logic clk, load_wr, sound_io_rd,
    input logic [24:0] load_addr,
    input logic [15:0] load_data, za,
    input logic [7:0] sound_io_read_data, ram_data, sound_latch,
    output wire [7:0] zdin
);
    logic [15:0] sound_rom [0:1023];
    always_ff @(posedge clk) begin
        if (load_wr && load_addr >= 'h20100 && load_addr < 'h30100)
            sound_rom[10'((load_addr-'h20100)>>1)] <= load_data;
    end
    logic [15:0] word_q;
    logic lane_q, rom_selected_q;
    logic [7:0] nonrom_q;
    always_ff @(posedge clk) begin
        word_q <= sound_rom[za[10:1]];
        lane_q <= za[0];
        rom_selected_q <= !sound_io_rd && za < 'hc000;
        if (sound_io_rd) nonrom_q <= sound_io_read_data;
        else if (za >= 'hc000 && za < 'hc800) nonrom_q <= ram_data;
        else if (za == 'he000) nonrom_q <= sound_latch;
        else nonrom_q <= 8'hff;
    end
    assign zdin = rom_selected_q ? (lane_q ? word_q[15:8] : word_q[7:0]) : nonrom_q;
endmodule
