// Private scaled inference probe. Source contract and limits are in manifest.json.
module SoundLegacy (
    input logic clk, load_wr, sound_io_rd,
    input logic [24:0] load_addr,
    input logic [15:0] load_data, za,
    input logic [7:0] sound_io_read_data, ram_data, sound_latch,
    output logic [7:0] zdin
);
    logic [15:0] sound_rom [0:1023];
    always_ff @(posedge clk) begin
        if (load_wr) begin
            if (load_addr >= 'h20100 && load_addr < 'h30100)
                sound_rom[10'((load_addr-'h20100)>>1)] <= load_data;
        end
    end
    always_ff @(posedge clk) begin
        if (sound_io_rd) zdin <= sound_io_read_data;
        else if (za < 'hc000) zdin <= za[0] ? sound_rom[za[10:1]][15:8] : sound_rom[za[10:1]][7:0];
        else if (za < 'hc800) zdin <= ram_data;
        else if (za == 'he000) zdin <= sound_latch;
        else zdin <= 8'hff;
    end
endmodule
