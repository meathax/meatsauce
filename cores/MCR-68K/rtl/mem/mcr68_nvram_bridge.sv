// -----------------------------------------------------------------------------
// mcr68_nvram_bridge.sv
//
// Glue between hps_io's WIDE=1 ioctl_download/ioctl_upload streams (16-bit
// words, byte order dout[7:0]=even address, dout[15:8]=odd address -- see
// rtl/mem/mcr68_rom_loader.sv's own header for the same convention) and
// mcr68_mem_hw's byte-addressed NVRAM port (rtl/mcr68_mem_hw.sv).
//
// Evidence for what this backs: Arch Rivals schematic sheet 2 (manual
// 16-4001-K-101) -- work RAM is two 2064s, 4B (low/LDS byte) is battery-
// backed. This bridge is title-agnostic; it is only wired live when the
// integrator's .mra declares an <nvram index="..." size="..."/> tag for a
// given game, so it has no effect on titles that don't.
//
// Download (load): on each ioctl_wr beat for the matching index, the 16-bit
// word covers two consecutive byte addresses. ioctl_wr beats arrive at the
// (SPI-derived) hps_io rate -- many clk_sys cycles apart -- so a two-state
// sequencer safely issues the two byte writes back to back well before the
// next beat, and nvram_wr/nvram_addr/nvram_din are muxed to this sequencer's
// registered values only while it is actually writing.
//
// Upload (save): ioctl_din must present the CURRENT word's two bytes fast
// relative to the SPI polling rate. A free-running 2-phase reader
// continuously walks the even/odd byte pair at ioctl_addr and shadows them
// into ioctl_din; the mem_hw read port has one cycle of latency, so the
// phase toggle accounts for that when it decides which shadow register a
// given nvram_dout sample belongs to.
//
// Download and upload are never simultaneously active on one hps_io
// instance, so nvram_addr/nvram_din can be a simple priority mux and there
// is no write/read contention on the shared port.
// -----------------------------------------------------------------------------

`default_nettype none
module mcr68_nvram_bridge #(
    parameter int unsigned BYTES = 8192,
    parameter int unsigned AW    = $clog2(BYTES)
) (
    input  logic         clk,
    input  logic         rst,

    // ---- hps_io side ----
    input  logic         ioctl_download,
    input  logic         ioctl_upload,
    input  logic         ioctl_wr,
    input  logic [26:0]  ioctl_addr,
    input  logic [15:0]  ioctl_dout,
    output logic [15:0]  ioctl_din,
    input  logic         sel,          // this stream's ioctl_index matches

    // ---- mcr68_mem_hw NVRAM port ----
    output logic          nvram_wr,
    output logic [AW-1:0] nvram_addr,
    output logic [7:0]    nvram_din,
    input  logic  [7:0]   nvram_dout
);

    // ---- download: split one 16-bit beat into two sequential byte writes ----
    typedef enum logic [1:0] {D_IDLE, D_LO, D_HI} dstate_e;
    dstate_e       dstate;
    logic [AW-1:0] dword_addr;
    logic [15:0]   dword_data;
    logic          d_wr;
    logic [AW-1:0] d_addr;
    logic [7:0]    d_din;

    always_ff @(posedge clk) begin
        if (rst) begin
            dstate <= D_IDLE;
            d_wr   <= 1'b0;
        end else begin
            d_wr <= 1'b0;
            unique case (dstate)
                D_IDLE: begin
                    if (sel && ioctl_download && ioctl_wr) begin
                        dword_addr <= ioctl_addr[AW-1:0];
                        dword_data <= ioctl_dout;
                        dstate     <= D_LO;
                    end
                end
                D_LO: begin
                    d_addr <= dword_addr;
                    d_din  <= dword_data[7:0];
                    d_wr   <= 1'b1;
                    dstate <= D_HI;
                end
                D_HI: begin
                    d_addr <= dword_addr + 1'b1;
                    d_din  <= dword_data[15:8];
                    d_wr   <= 1'b1;
                    dstate <= D_IDLE;
                end
                default: dstate <= D_IDLE;
            endcase
        end
    end

    // ---- upload: free-running 2-phase reader ----
    logic          uphase;      // 0 -> address driven this cycle is 'even', 1 -> 'odd'
    logic [7:0]    ushadow_lo, ushadow_hi;
    logic [AW-1:0] u_read_addr;
    logic [AW-1:0] uaddr_even;

    assign uaddr_even = {ioctl_addr[AW-1:1], 1'b0};
    assign u_read_addr = uphase ? (uaddr_even + 1'b1) : uaddr_even;

    always_ff @(posedge clk) begin
        if (rst) begin
            uphase <= 1'b0;
        end else if (sel && ioctl_upload) begin
            uphase <= ~uphase;
            // nvram_dout this cycle reflects the address driven last cycle,
            // i.e. the *previous* value of uphase/u_read_addr.  Because the
            // current phase has already toggled at this edge, the delayed
            // sample is the opposite phase: uphase=1 samples the prior even
            // address, while uphase=0 samples the prior odd address.
            if (uphase) ushadow_lo <= nvram_dout; // previous cycle drove even
            else        ushadow_hi <= nvram_dout; // previous cycle drove odd
        end
    end

    // ---- shared port mux: download writes take priority; otherwise the
    //      upload reader owns the address so ioctl_din keeps refreshing ----
    assign nvram_wr   = d_wr;
    assign nvram_addr = d_wr ? d_addr : u_read_addr;
    assign nvram_din  = d_din;
    assign ioctl_din  = {ushadow_hi, ushadow_lo};

endmodule
`default_nettype wire
