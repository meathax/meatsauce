// kf8253_leland_bus -- bus-decode wrapper adapting this repo's generic
// access/ack/wr_en/bytesel bus convention (the same one i186_periph.sv
// uses on its sys-side port) onto vendored KF8253's native
// chip_select_n/read_enable_n/write_enable_n/address[1:0] strobe bus.
//
// Scope boundary: this module does NOT decode a real system address into
// "is this access for me" -- that is the PCS-window job (MAME's leland_a.cpp
// peripheral_r/w, `select = offset >> 6`, PCS2/PCS3 sub-windows). This module assumes it has already
// been selected (`access` asserted) and only needs `local_addr[1:0]`
// (the KF8253 register select: 00/01/10 = counter 0/1/2, 11 = control
// -- as the game's sound code programs it) to talk to the chip correctly.
//
// Why a 2-cycle FSM, not a 1-cycle passthrough: KF8253_Control_Logic's
// write commit is edge-triggered on write_enable_n's 0->1 transition
// while chip_select_n stays low (`write_flag = ~prev_write_enable_n &
// write_enable_n`, both sampled on `negedge clock`) -- a single-cycle
// `write_enable_n` pulse that only ever *starts* low never produces
// the rising edge the chip is actually watching for. Reads are level-
// sensitive and would work in 1 cycle, but this module uses the same
// 2-cycle shape for both directions for simplicity/symmetry.
module kf8253_leland_bus(
    input  logic        clk,
    input  logic        reset,

    // Generic bus (already address-selected by the caller)
    input  logic [1:0]  local_addr,
    input  logic [15:0]  data_in,
    output logic [15:0] data_out,
    input  logic        access,
    output logic        ack,
    input  logic         wr_en,
    input  logic [1:0]  bytesel,   // 01=low-byte lane, 10=high-byte
                                    // lane, 11=word (low byte used --
                                    // the game's writes are all
                                    // low-byte-lane)

    // PIT chip I/O
    input  logic counter_0_clock, counter_0_gate, output logic counter_0_out,
    input  logic counter_1_clock, counter_1_gate, output logic counter_1_out,
    input  logic counter_2_clock, counter_2_gate, output logic counter_2_out
);

logic        cs_n, rd_n, we_n;
logic [1:0]  kf_addr;
logic [7:0]  kf_data_in;
logic [7:0]  kf_data_out;

KF8253 u_kf8253(
    .clock(clk), .reset(reset),
    .chip_select_n(cs_n), .read_enable_n(rd_n), .write_enable_n(we_n),
    .address(kf_addr), .data_bus_in(kf_data_in), .data_bus_out(kf_data_out),
    .counter_0_clock(counter_0_clock), .counter_0_gate(counter_0_gate), .counter_0_out(counter_0_out),
    .counter_1_clock(counter_1_clock), .counter_1_gate(counter_1_gate), .counter_1_out(counter_1_out),
    .counter_2_clock(counter_2_clock), .counter_2_gate(counter_2_gate), .counter_2_out(counter_2_out));

// S_WAIT: holds after the transaction's effect is complete until the
// caller actually drops `access` -- without this, a caller that
// hasn't yet reacted to `ack` (still holding access high the cycle
// after) would fall straight back into S_IDLE and get re-triggered as
// a brand-new transaction. Same access/ack race class documented and
// fixed in rtl/cpu/i186_periph.sv; the same structure is handled here.
typedef enum logic [2:0] {S_IDLE, S_WR0, S_WR1, S_RD0, S_WAIT} state_t;
state_t state;

wire [7:0] wr_byte = (bytesel == 2'b10) ? data_in[15:8] : data_in[7:0];

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        state      <= S_IDLE;
        cs_n       <= 1'b1;
        rd_n       <= 1'b1;
        we_n       <= 1'b1;
        kf_addr    <= 2'b00;
        kf_data_in <= 8'h00;
        ack        <= 1'b0;
        data_out   <= 16'h0000;
    end else begin
        ack <= 1'b0;
        case (state)
            S_IDLE: begin
                if (access) begin
                    cs_n    <= 1'b0;
                    kf_addr <= local_addr;
                    if (wr_en) begin
                        kf_data_in <= wr_byte;
                        we_n       <= 1'b0; // first half of the 0->1
                                             // write-commit edge
                        state      <= S_WR0;
                    end else begin
                        rd_n  <= 1'b0;
                        state <= S_RD0;
                    end
                end
            end
            S_WR0: begin
                we_n  <= 1'b1; // rising edge here is what KF8253's
                                // control logic actually latches on
                ack   <= 1'b1;
                state <= S_WR1;
            end
            S_WR1: begin
                cs_n  <= 1'b1;
                state <= S_WAIT;
            end
            S_RD0: begin
                data_out <= {8'h00, kf_data_out};
                cs_n     <= 1'b1;
                rd_n     <= 1'b1;
                ack      <= 1'b1;
                state    <= S_WAIT;
            end
            S_WAIT: begin
                if (!access)
                    state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
