// MCR-68k MRA DIP configuration receiver.
//
// MiSTer sends the selected <switches> value from an MRA as a download at
// ioctl index 254. The production hps_io instance is WIDE=1, so each write
// carries two successive bytes in ioctl_dout[7:0] then ioctl_dout[15:8], and
// ioctl_addr advances by two. The low byte is the DSW port read by all four
// supported MCR-68k profiles; the remaining bytes are retained so the
// receiver implements the complete 64-bit MRA contract even though this
// board only consumes byte 0.
//
// If an older MRA has no DIP stream, the profile-specific factory default is
// still presented. A profile transition reinitializes the stored bytes before
// a new MRA DIP stream overrides them.

module mcr68_dip_config (
    input  logic        clk,
    input  logic        poweron_rst,
    input  logic [2:0]  game,
    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic [7:0]  dsw
);

    logic [7:0] dip_byte [0:7];
    logic [2:0] game_q;
    integer i;

    function automatic logic [7:0] factory_dsw(input logic [2:0] profile);
        case (profile)
            3'd0: factory_dsw = 8'h3c; // Xenophobe: SW1:3..8
            3'd1: factory_dsw = 8'hf3; // Blasted: coinage/difficulty/etc.
            3'd3: factory_dsw = 8'hff; // Arch Rivals: all factory defaults high
            3'd4: factory_dsw = 8'hff; // Pigskin: all factory defaults high
            default: factory_dsw = 8'hff;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (poweron_rst) begin
            game_q <= game;
            for (i = 0; i < 8; i = i + 1)
                dip_byte[i] <= 8'hff;
            dip_byte[0] <= factory_dsw(game);
        end else begin
            if (game != game_q) begin
                game_q <= game;
                for (i = 0; i < 8; i = i + 1)
                    dip_byte[i] <= 8'hff;
                dip_byte[0] <= factory_dsw(game);
            end

            if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) &&
                (ioctl_addr[26:3] == 24'd0)) begin
                // WIDE=1 writes land at even byte addresses. The explicit
                // cases keep the second-byte write bounded; the odd-address
                // cases also make the block tolerant of a WIDE=0 diagnostic
                // harness without changing the production path.
                case (ioctl_addr[2:0])
                    3'd0: begin dip_byte[0] <= ioctl_dout[7:0];  dip_byte[1] <= ioctl_dout[15:8]; end
                    3'd1: begin dip_byte[1] <= ioctl_dout[7:0]; end
                    3'd2: begin dip_byte[2] <= ioctl_dout[7:0];  dip_byte[3] <= ioctl_dout[15:8]; end
                    3'd3: begin dip_byte[3] <= ioctl_dout[7:0]; end
                    3'd4: begin dip_byte[4] <= ioctl_dout[7:0];  dip_byte[5] <= ioctl_dout[15:8]; end
                    3'd5: begin dip_byte[5] <= ioctl_dout[7:0]; end
                    3'd6: begin dip_byte[6] <= ioctl_dout[7:0];  dip_byte[7] <= ioctl_dout[15:8]; end
                    3'd7: begin dip_byte[7] <= ioctl_dout[7:0]; end
                    default: begin end
                endcase
            end
        end
    end

    assign dsw = dip_byte[0];

endmodule
