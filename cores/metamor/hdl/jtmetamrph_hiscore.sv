// SPDX-License-Identifier: GPL-3.0-or-later
// Metamorphic Force: MAME hiscore.dat maincpu:203240,35,00,5a.
// Reuses the existing 512-byte save BRAM after the 128-byte EEPROM, so the
// MRA NVRAM layout remains 640 bytes. The distinct MF signature rejects donor
// Violent Storm score data. The odd last byte never overwrites its neighbour.
module jtmetamrph_hiscore (
    input rst, clk, transfer,
    input cpu_wr,
    input [23:1] cpu_a,
    input [15:0] cpu_dout,
    input [1:0] cpu_dsn,
    input cpu_idle,
    output reg inj_req,
    output reg [23:1] inj_a,
    output reg [15:0] inj_d,
    output reg [1:0] inj_dsn,
    input ram_ok,
    output busy,
    output reg [8:1] hs_addr,
    output reg [15:0] hs_din,
    output reg [1:0] hs_we,
    input [15:0] hs_dout
);
    localparam [23:0] FIRST=24'h203240, LAST=24'h203274;
    localparam [15:0] MAGIC=16'h4d46;
    localparam [2:0] INIT=0, CHECK=1, WAIT_INIT=2, READ=3, WRITE=4, MIRROR=5;
    reg [2:0] state;
    reg [1:0] delay_read;
    reg [7:0] first_byte, last_byte;
    reg valid;
    reg [4:0] word_index;
    wire [23:0] address = {1'b0,cpu_a[22:1],1'b0};
    wire in_table = address >= FIRST && address <= LAST;
    wire [23:0] offset = (address-FIRST)>>1;
    wire ready = first_byte==8'h00 && last_byte==8'h5a;
    // Let an already-started bus cycle finish, then hold the CPU idle for the
    // complete restore, including BRAM read waits between injected words.
    assign busy = inj_req | (valid && cpu_idle && (state==READ || state==WRITE));

    always @(posedge clk) begin
        hs_we <= 0;
        if (rst) begin
            state<=INIT; delay_read<=0; first_byte<=8'hff; last_byte<=8'hff;
            valid<=0; word_index<=0; inj_req<=0; inj_a<=0; inj_d<=0;
            inj_dsn<=2'b11; hs_addr<=0; hs_din<=0;
        end else begin
            if (cpu_wr && in_table && !cpu_dsn[1]) begin
                if (address==FIRST) first_byte<=cpu_dout[15:8];
                if (address==LAST)  last_byte<=cpu_dout[15:8];
            end
            // Host transfer owns the shared save BRAM. Preserve observed
            // initialization bytes so late loads can restore an initialized game.
            if (transfer) begin
                state<=INIT; valid<=0; inj_req<=0;
            end else case (state)
                INIT: begin hs_addr<=8'd255; delay_read<=2; state<=CHECK; end
                CHECK: if (delay_read!=0) delay_read<=delay_read-1'b1;
                    else begin valid<=hs_dout==MAGIC; state<=WAIT_INIT; end
                WAIT_INIT: begin
                    if (!valid && cpu_wr && in_table) begin
                        hs_addr<=offset[7:0]; hs_din<=cpu_dout;
                        hs_we<=~cpu_dsn & (address==LAST ? 2'b10 : 2'b11);
                    end
                    if (ready) begin
                        if (valid) begin
                            word_index<=0; hs_addr<=0; delay_read<=2; state<=READ;
                        end else begin
                            hs_addr<=8'd255; hs_din<=MAGIC; hs_we<=2'b11; state<=MIRROR;
                        end
                    end
                end
                READ: if (delay_read!=0) delay_read<=delay_read-1'b1;
                    else if (cpu_idle) begin
                        inj_a<=FIRST[23:1]+word_index; inj_d<=hs_dout;
                        inj_dsn<=word_index==26 ? 2'b01 : 2'b00;
                        inj_req<=1; state<=WRITE;
                    end
                WRITE: if (ram_ok && inj_req) begin
                    inj_req<=0;
                    if (word_index==26) state<=MIRROR;
                    else begin
                        word_index<=word_index+1'b1; hs_addr<=word_index+1'b1;
                        delay_read<=2; state<=READ;
                    end
                end
                MIRROR: if (cpu_wr && in_table) begin
                    hs_addr<=offset[7:0]; hs_din<=cpu_dout;
                    hs_we<=~cpu_dsn & (address==LAST ? 2'b10 : 2'b11);
                end
                default: state<=INIT;
            endcase
        end
    end
endmodule
