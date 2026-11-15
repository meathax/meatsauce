// Board-specific write registers from MAME0.289 cyclwarr.cpp/tatsumi.cpp.
// CRTC storage preserves software writes; timing generation is a separate block.
module bigfight_registers (
    input logic clk, cold_start, reset, req, wr,
    input logic [23:1] address,
    input logic uds_n, lds_n,
    input logic [15:0] din,
    output logic selected,
    output logic [63:0] video_config,
    output logic [15:0] tile_bank, mixing_control,
    output logic [511:0] crtc_regs,
    output logic [7:0] sound_command,
    output logic sound_command_strobe,
    output logic [1:0] coin_outputs
);
    logic [5:0] crtc_index;
    wire [23:0] a = {address,1'b0};
    always_comb begin
        selected = (a >= 24'h0a2000 && a <= 24'h0a2006) ||
                   a == 24'h0a4000 || a == 24'h0a6000 ||
                   a == 24'h0ac000 || a == 24'h0ac002 ||
                   a == 24'h0b8000 || a == 24'h0bc000;
    end
    always_ff @(posedge clk) begin
        sound_command_strobe <= 1'b0;
        if (cold_start) begin
            video_config <= '0;
            tile_bank <= '0;
            mixing_control <= '0;
            crtc_regs <= '0;
            crtc_index <= '0;
            sound_command <= '0;
            coin_outputs <= '0;
        end else if (!reset && req && wr && selected) begin
            if (a >= 24'h0a2000 && a <= 24'h0a2006) begin
                if (!uds_n) video_config[a[2:1]*16+8 +: 8] <= din[15:8];
                if (!lds_n) video_config[a[2:1]*16 +: 8] <= din[7:0];
            end
            if (a == 24'h0a4000) begin
                if (!uds_n) tile_bank[15:8] <= din[15:8];
                if (!lds_n) tile_bank[7:0] <= din[7:0];
            end
            if (a == 24'h0a6000) begin
                if (!uds_n) mixing_control[15:8] <= din[15:8];
                if (!lds_n) mixing_control[7:0] <= din[7:0];
            end
            if (a == 24'h0ac000 && !lds_n) crtc_index <= din[5:0];
            if (a == 24'h0ac002 && !lds_n) crtc_regs[crtc_index*8 +: 8] <= din[7:0];
            if (a == 24'h0b8000 && !uds_n) begin
                sound_command <= din[15:8];
                sound_command_strobe <= 1'b1;
            end
            if (a == 24'h0bc000 && !lds_n) coin_outputs <= din[1:0];
        end
    end
endmodule
