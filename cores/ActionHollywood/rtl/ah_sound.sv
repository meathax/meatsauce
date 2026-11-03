// ah_sound -- Action Hollywood sound: actionhw_snd_w HLE (kickgoal.cpp 359-443) + OKI M6295 (jt6295)
//
// Single clock domain: clk = 47.95395 MHz (clock_plan.json), OKI 1 MHz clock enable = exact n/m fractional enable
// 1 MHz/clk = 20000/959079 (PCB 12 MHz/12; 47 or 48 clk apart).
// PIN7 HIGH on the PCB -> jt6295 ss=1 -> sample rate 1 MHz/132 = 7.576 kHz (MAME PIN7_HIGH divisor 132).
// OKI ROM bank: 4 x 128 KB entries of the 512 KB OKI region; OKI addr[17]=0 -> region[0..0x1ffff]
// (always bank-0 data, MAME oki_map rom()), addr[17]=1 -> entry `bank` (reset value 1, MAME set_entry(1)).
// ROM client port: byte image base 0x100000 included in oki_addr (32-bit word index).
//
// Extra pure-simulation observability is done by the testbench through hierarchical references only,
// so the module port list is exactly the one in docs/CONTRACTS.md.
module ah_sound(
    input                clk,
    input                rst,
    input                pause,
    input                snd_we,
    input         [15:0] snd_data,
    input                snd_uds_n,
    input                snd_lds_n,
    output reg           oki_req,
    output        [22:2] oki_addr,
    input                oki_ack,
    input         [31:0] oki_data,
    output signed [15:0] audio
);

// ---------------------------------------------------------------- 1 MHz clock enable
localparam [19:0] OKI_NUM = 20'd20000, OKI_DEN = 20'd959079;   // 1 MHz / 47.95395 MHz
reg  [19:0] cacc;
reg         cen;
wire [20:0] csum = {1'b0,cacc} + {1'b0,OKI_NUM};
always @(posedge clk) begin
    if (rst) begin
        cacc <= 20'd0;
        cen  <= 1'b0;
    end else begin
        cen <= 1'b0;
        if (!pause) begin
            if (csum >= {1'b0,OKI_DEN}) begin cacc <= csum[19:0] - OKI_DEN; cen <= 1'b1; end
            else cacc <= csum[19:0];
        end
    end
end

// ---------------------------------------------------------------- write FIFO (68k write order is kept)
// d16 = ACCESSING_BITS_0_7 ? data : data >> 8   (MAME "if (!ACCESSING_BITS_0_7) data >>= 8")
wire [15:0] wr_d16 = snd_lds_n ? {8'h00, snd_data[15:8]} : snd_data;
wire        wr_acc = snd_we & ~(snd_uds_n & snd_lds_n);

reg [15:0] fifo [0:15];
reg [3:0]  f_wp, f_rp;
reg [4:0]  f_cnt;
wire       f_empty = (f_cnt == 5'd0);
reg        f_pop;

always @(posedge clk) begin
    if (rst) begin
        f_wp  <= 4'd0;
        f_rp  <= 4'd0;
        f_cnt <= 5'd0;
    end else begin
        if (wr_acc && f_cnt != 5'd16) begin
            fifo[f_wp] <= wr_d16;
            f_wp <= f_wp + 4'd1;
        end
        if (f_pop) f_rp <= f_rp + 4'd1;
        f_cnt <= f_cnt + ((wr_acc && f_cnt != 5'd16) ? 5'd1 : 5'd0) - (f_pop ? 5'd1 : 5'd0);
    end
end

// ---------------------------------------------------------------- OKI instance
reg         oki_wrn;
reg  [7:0]  oki_din;
wire [7:0]  oki_dout;
wire [17:0] oki_rom_addr;
wire [7:0]  oki_rom_data;
wire        oki_rom_ok;
wire signed [13:0] oki_snd;
wire        oki_sample;
wire [3:0]  oki_busy = oki_dout[3:0];     // busy | start (MAME read() & 0x0f)

jt6295 #(.INTERPOL(0)) u_oki(
    .rst      ( rst          ),
    .clk      ( clk          ),
    .cen      ( cen          ),
    .ss       ( 1'b1         ),   // PIN7 HIGH
    .wrn      ( oki_wrn      ),
    .din      ( oki_din      ),
    .dout     ( oki_dout     ),
    .rom_addr ( oki_rom_addr ),
    .rom_data ( oki_rom_data ),
    .rom_ok   ( oki_rom_ok   ),
    .sound    ( oki_snd      ),
    .sample   ( oki_sample   )
);

// ---------------------------------------------------------------- bank + ROM client with 1-word cache
reg [1:0] bank;                              // OKI bank entry (reset: 1)
wire [18:0] reg_off = oki_rom_addr[17] ? {bank, oki_rom_addr[16:0]} : {2'b00, oki_rom_addr[16:0]};
wire [16:0] cur_w   = reg_off[18:2];         // 32-bit word index inside the 512 KB OKI region

reg [16:0] c_tag;
reg        c_val;
reg [31:0] c_dat;
reg [16:0] r_tag;                            // tag of the request in flight

assign oki_addr = {2'b00, 1'b1, 1'b0, r_tag};   // 0x100000 + word*4 -> [22:2]: bit20 -> [20:2]
wire hit = c_val && (c_tag == cur_w);

always @(posedge clk) begin
    if (rst) begin
        oki_req <= 1'b0;
        c_val   <= 1'b0;
        c_tag   <= 17'd0;
        r_tag   <= 17'd0;
        c_dat   <= 32'd0;
    end else begin
        if (oki_req) begin
            if (oki_ack) begin
                oki_req <= 1'b0;
                c_dat   <= oki_data;
                c_tag   <= r_tag;
                c_val   <= 1'b1;
            end
        end else if (!hit) begin
            oki_req <= 1'b1;
            r_tag   <= cur_w;
        end
    end
end

assign oki_rom_ok = hit;
reg [7:0] rd_byte;
always @* begin
    case (reg_off[1:0])
        2'd0: rd_byte = c_dat[7:0];
        2'd1: rd_byte = c_dat[15:8];
        2'd2: rd_byte = c_dat[23:16];
        default: rd_byte = c_dat[31:24];
    endcase
end
assign oki_rom_data = rd_byte;

// ---------------------------------------------------------------- HLE FSM (actionhw_snd_w)
localparam [3:0] S_IDLE = 4'd0, S_DEC = 4'd1, S_CHAIN = 4'd2, S_OKIW = 4'd3, S_GAP = 4'd4, S_PEND = 4'd5;

reg  [3:0]  st;
reg  [15:0] d;               // current write value
reg  [15:0] snd_new;         // m_snd_new (int)
reg  [15:0] sam [0:3];       // m_snd_sam[4] (only ever cleared by the original code)
reg  [1:0]  stg;             // chain stage 3..0: tests (data&0x80,sam[3],busy 8) ... (data&0x10,sam[0],busy 1)
reg  [7:0]  w0, w1;          // OKI byte queue
reg  [1:0]  w_n;             // bytes remaining
reg  [1:0]  w_i;
reg         w_chain;         // after the OKI write return to chain (else IDLE)
reg  [3:0]  pend;            // voices started, waiting to show in status
reg  [7:0]  gap;
reg  [17:0] tmo;

wire        d_hi_gt   = (d > 16'h0080);
wire [3:0]  stg_bit   = 4'd1 << (stg);          // stg=3 -> 0x80 test ... ; maps data bit 4+stg
wire        bit_set   = d[4 + stg];
wire        sam_ne    = (sam[stg] != snd_new);
wire        is_busy   = oki_busy[stg];

integer i;
always @(posedge clk) begin
    f_pop <= 1'b0;
    if (rst) begin
        st      <= S_IDLE;
        bank    <= 2'd1;
        snd_new <= 16'd0;
        for (i = 0; i < 4; i = i + 1) sam[i] <= 16'd0;
        oki_wrn <= 1'b1;
        oki_din <= 8'd0;
        pend    <= 4'd0;
        w_n     <= 2'd0;
        w_chain <= 1'b0;
        gap     <= 8'd0;
        tmo     <= 18'd0;
        stg     <= 2'd3;
        d       <= 16'd0;
        w0      <= 8'd0;
        w1      <= 8'd0;
        w_i     <= 2'd0;
    end else begin
        case (st)
        S_IDLE: begin
            oki_wrn <= 1'b1;
            if (!f_empty) begin
                d     <= fifo[f_rp];
                f_pop <= 1'b1;
                st    <= S_DEC;
            end
        end
        S_DEC: begin
            case (d)
            16'h00fc: begin bank <= 2'd0; st <= S_IDLE; end
            16'h00fd: begin bank <= 2'd2; st <= S_IDLE; end
            16'h00fe: begin bank <= 2'd1; st <= S_IDLE; end
            16'h00ff: begin bank <= 2'd3; st <= S_IDLE; end
            16'h0078: begin
                w0 <= 8'h78; w_n <= 2'd1; w_i <= 2'd0; w_chain <= 1'b0; st <= S_OKIW;
                for (i = 0; i < 4; i = i + 1) sam[i] <= 16'd0;
            end
            default: begin
                if (snd_new != 16'd0) begin
                    stg <= 2'd3; st <= S_CHAIN;
                end else if (d_hi_gt) begin
                    snd_new <= d; st <= S_IDLE;
                end else begin
                    // turn channel(s) off
                    w0 <= d[7:0]; w_n <= 2'd1; w_i <= 2'd0; w_chain <= 1'b0; st <= S_OKIW;
                    if (d[6]) sam[3] <= 16'd0;
                    if (d[5]) sam[2] <= 16'd0;
                    if (d[4]) sam[1] <= 16'd0;
                    if (d[3]) sam[0] <= 16'd0;
                    snd_new <= 16'd0;
                end
            end
            endcase
        end
        S_CHAIN: begin
            // stage stg tests (d & (0x10<<stg)) && sam[stg] != snd_new ; play if oki status bit (1<<stg) clear
            if (bit_set && sam_ne) begin
                snd_new <= 16'd0;
                if (!is_busy) begin
                    w0 <= snd_new[7:0]; w1 <= d[7:0]; w_n <= 2'd2; w_i <= 2'd0;
                    pend <= 4'd1 << stg;
                    tmo  <= 18'd0;
                    w_chain <= (stg != 2'd0);
                    st <= S_OKIW;
                end else if (stg == 2'd0) st <= S_IDLE;
                else stg <= stg - 2'd1;
            end else if (stg == 2'd0) st <= S_IDLE;
            else stg <= stg - 2'd1;
        end
        S_OKIW: begin
            // present one byte as a 1-clk low wrn pulse
            oki_din <= (w_i == 2'd0) ? w0 : w1;
            oki_wrn <= 1'b0;
            gap     <= 8'd0;
            st      <= S_GAP;
        end
        S_GAP: begin
            oki_wrn <= 1'b1;
            gap     <= gap + 8'd1;
            if (gap == 8'd15) begin
                if (w_i + 2'd1 < w_n) begin w_i <= w_i + 2'd1; st <= S_OKIW; end
                else if (pend != 4'd0) st <= S_PEND;
                else st <= w_chain ? S_CHAIN : S_IDLE;
            end
        end
        S_PEND: begin
            // wait until the start shows in the OKI status (MAME shows busy instantly), bounded
            tmo <= tmo + 18'd1;
            if (((oki_busy & pend) == pend) || tmo == 18'd200000) begin
                pend <= 4'd0;
                if (stg == 2'd0 || !w_chain) st <= S_IDLE;
                else begin stg <= stg - 2'd1; st <= S_CHAIN; end
            end
        end
        default: st <= S_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------- output scaling
// MAME: out = adpcm12 * vol/2048 * 0.80 route, full scale = 32768 -> 16 * 0.8 = 12.8 per jt6295 LSB
wire signed [23:0] mul = $signed(oki_snd) * 24'sd205;      // 205/16 = 12.8125
wire signed [23:0] shf = mul >>> 4;
wire sat_hi = (shf >  24'sd32767);
wire sat_lo = (shf < -24'sd32768);
reg signed [15:0] aud_r;
always @(posedge clk) begin
    if (rst) aud_r <= 16'sd0;
    else aud_r <= sat_hi ? 16'sh7fff : sat_lo ? 16'sh8000 : shf[15:0];
end
assign audio = aud_r;

endmodule
