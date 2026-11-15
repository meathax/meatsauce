// Native Main_MiSTer address= download, then burst reads into the existing
// SDRAM word writer. No local/game reset may discard accepted DDR replies.
module rf_ddr_rom (
    input wire clk, init,
    input wire download, wr,
    input wire [7:0] index,
    input wire [26:0] addr,
    input wire word_busy,
    output wire word_wr,
    output wire [26:0] word_addr,
    output wire [15:0] word_data,
    output reg active = 0,
    output reg error = 0,
    output wire [28:0] ddr_addr,
    output wire [7:0] ddr_burstcnt,
    output wire ddr_rd,
    input wire ddr_busy,
    input wire [63:0] ddr_data,
    input wire ddr_ready
);
    // One burst may be outstanding. Reserve its entire capacity before issue.
    // Two bursts of buffering overlap DDR latency with the SDRAM writer.
    (* ramstyle = "MLAB" *) reg [63:0] fifo [0:15];
    reg [3:0] wp, rp;
    reg [4:0] used;
    reg [3:0] owed;
    reg [26:0] fetch_addr, length, emit_addr;
    reg [1:0] lane;
    reg was_rom = 0, streamed = 0;
    wire rom = download && index == 0;
    wire [26:0] bytes_left = length - fetch_addr;
    wire [7:0] burst = bytes_left >= 64 ? 8'd8
                       : {4'd0, bytes_left[5:3]} + (|bytes_left[2:0] ? 8'd1 : 8'd0);
    assign ddr_addr = 29'h06000000 + {5'd0, fetch_addr[26:3]}; // 0x30000000 / 8
    assign ddr_burstcnt = burst;
    assign ddr_rd = active && fetch_addr < length && owed == 0 && used <= 8;
    wire accept = ddr_rd && !ddr_busy;
    wire push = ddr_ready && owed != 0;
    assign word_wr = active && emit_addr < length && used != 0 && !word_busy;
    assign word_addr = emit_addr;
    assign word_data = fifo[rp][lane*16 +: 16];
    wire pop = word_wr && (lane == 3 || emit_addr + 27'd2 == length);

    always @(posedge clk) begin
        was_rom <= rom;
        if (init) begin
            active <= 0; error <= 0; was_rom <= 0; streamed <= 0;
            wp <= 0; rp <= 0; used <= 0; owed <= 0;
            fetch_addr <= 0; emit_addr <= 0; length <= 0; lane <= 0;
        end else begin
            if (rom && !was_rom) begin
                streamed <= wr;
                if (active) error <= 1; // HPS must respect ioctl_wait
                else error <= 0;
            end else if (rom && wr) streamed <= 1;
            // Main supplies the length through FIO_FILE_TX, including its end.
            if (was_rom && !rom && !streamed && !active) begin
                if (addr == 0 || addr[0]) error <= 1;
                else begin
                    active <= 1;
                    length <= addr; fetch_addr <= 0; emit_addr <= 0;
                    wp <= 0; rp <= 0; used <= 0; owed <= 0; lane <= 0;
                end
            end
            if (accept) begin
                owed <= burst[3:0];
                fetch_addr <= fetch_addr + {16'd0, burst, 3'd0};
            end else if (push) owed <= owed - 1'b1;
            if (push) begin fifo[wp] <= ddr_data; wp <= wp + 1'b1; end
            if (pop) rp <= rp + 1'b1;
            case ({push, pop})
                2'b10: used <= used + 1'b1;
                2'b01: used <= used - 1'b1;
                default: ;
            endcase
            if (word_wr) begin
                emit_addr <= emit_addr + 27'd2;
                lane <= lane + 1'b1;
            end
            // word_busy covers the actual SDRAM acknowledgement crossing.
            if (active && emit_addr == length && used == 0 && owed == 0 && !word_busy)
                active <= 0;
        end
    end
endmodule
