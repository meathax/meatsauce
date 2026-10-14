// Sega 315-5296 behavior from MAME 315_5296.cpp.
module s24_io_5296 (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_16m,
    input  logic        rd,
    input  logic        wr,
    input  logic [5:0]  addr,
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    input  logic [63:0] port_in,
    output logic [63:0] port_out,
    output logic [7:0]  port_dir,
    // Pulses when MAME's per-port output callback would run: a write while
    // that port is an output, or a direction transition in either direction.
    output logic [7:0]  port_write,
    // Callback payload captured with port_write.  This is explicit because
    // the live latch/direction outputs update on the same clock edge.
    output logic [63:0] port_write_data,
    output logic [2:0]  cnt,
    output logic        cnt2_clock,
    output logic        ckot_clock
);
    logic [7:0] latch [0:7];
    logic [7:0] cnt_reg;
    logic [3:0] cnt2_div_count,ckot_div_count;
    integer i;

    // CNT2 and CKOT divisor encodings from the 315-5296 register contract:
    // 00=CLK/4, 01=CLK/8, 10=CLK/16, 11=CLK/2. These are half-period
    // counts because the output toggles on each terminal count.
    function automatic logic [3:0] half_divisor(input logic [1:0] select);
        case (select)
            2'b00: half_divisor = 4'd2;
            2'b01: half_divisor = 4'd4;
            2'b10: half_divisor = 4'd8;
            default: half_divisor = 4'd1;
        endcase
    endfunction

    logic [3:0] cnt2_half_div,ckot_half_div;

    always_comb begin
        case (addr)
            6'h00,6'h01,6'h02,6'h03,6'h04,6'h05,6'h06,6'h07:
                dout = port_dir[addr[2:0]] ? latch[addr[2:0]]
                                           : port_in[addr[2:0]*8 +: 8];
            6'h08: dout = 8'h53; // S
            6'h09: dout = 8'h45; // E
            6'h0a: dout = 8'h47; // G
            6'h0b: dout = 8'h41; // A
            6'h0c,6'h0e: dout = cnt_reg;
            6'h0d,6'h0f: dout = port_dir;
            default: dout = 8'hff;
        endcase
    end

    always_comb begin
        for (int p = 0; p < 8; p++)
            port_out[p*8 +: 8] = port_dir[p] ? latch[p] : 8'h00;
        cnt = cnt_reg[2:0];
        cnt2_half_div = half_divisor(cnt_reg[5:4]);
        ckot_half_div = half_divisor(cnt_reg[7:6]);
        // CNT2 data bit 2 is ignored while clock mode (bit 3) is active.
        if (cnt_reg[3]) cnt[2] = cnt2_clock;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            port_dir <= 8'h00;
            port_write <= 8'h00;
            port_write_data <= 64'h0;
            cnt_reg <= 8'h00;
            cnt2_div_count <= 0;
            ckot_div_count <= 0;
            cnt2_clock <= 0;
            ckot_clock <= 0;
            for (i = 0; i < 8; i = i + 1) latch[i] <= 8'h00;
        end else begin
            port_write <= 8'h00;
            port_write_data <= 64'h0;
            if (ce_16m) begin
                if (cnt_reg[3]) begin
                    if (cnt2_div_count == cnt2_half_div - 1'b1) begin
                        cnt2_div_count <= 0;
                        cnt2_clock <= ~cnt2_clock;
                    end else cnt2_div_count <= cnt2_div_count + 1'b1;
                end
                if (ckot_div_count == ckot_half_div - 1'b1) begin
                    ckot_div_count <= 0;
                    ckot_clock <= ~ckot_clock;
                end else ckot_div_count <= ckot_div_count + 1'b1;
            end
            if (wr) begin
                case (addr)
                6'h00,6'h01,6'h02,6'h03,6'h04,6'h05,6'h06,6'h07: begin
                    latch[addr[2:0]] <= din;
                    if (port_dir[addr[2:0]]) begin
                        port_write[addr[2:0]] <= 1'b1;
                        port_write_data[addr[2:0]*8 +: 8] <= din;
                    end
                end
                6'h0e: begin
                    cnt_reg <= din;
                    cnt2_div_count <= 0;
                    ckot_div_count <= 0;
                    cnt2_clock <= 0;
                    ckot_clock <= 0;
                end
                6'h0f: begin
                    // 315_5296.cpp refreshes the output callback for every
                    // port whose direction changes.  The callback observes
                    // the latch when becoming output and zero when released.
                    port_write <= port_dir ^ din;
                    for (int p = 0; p < 8; p++) begin
                        if (port_dir[p] ^ din[p])
                            port_write_data[p*8 +: 8] <= din[p] ? latch[p] : 8'h00;
                    end
                    port_dir <= din;
                end
                default: ;
                endcase
            end
        end
    end
endmodule

// MahMahjan port-D callback.  This is deliberately strobe-driven: MAME
// advances on every callback carrying bit 2 high, including repeated writes
// of the same value, rather than only on a signal edge.
module s24_mahjong_mux (
    input  logic       clk,
    input  logic       reset,
    input  logic       enable,
    input  logic       port_d_write,
    input  logic [7:0] port_d_data,
    output logic [2:0] line
);
    always_ff @(posedge clk) begin
        if (reset || !enable)
            line <= 3'd0;
        else if (port_d_write && port_d_data[2])
            line <= line + 1'd1;
    end
endmodule
