// ah_hiscore: standard MiSTer hiscore support (rtl/hiscore/hiscore.sv, unmodified donor) glued to
//  * the 16-bit (hps_io WIDE) HPS download/upload bus,
//  * the ah_main work-RAM port (byte access while the 68000 is frozen),
//  * the single NVRAM file of the MRA (<nvram index="4" size="168">): bytes 0..127 = 93C46 EEPROM (handled by
//    ah_loader), bytes 128..167 = the 40-byte high-score table (this module).
//
// Why one file: Main_MiSTer stores one nvram index/size pair per MRA (lessons 9056/17122), so the EEPROM (was index 4)
// and the standard hiscore dump (HS_DUMPINDEX=4) cannot both own index 4.  The donor module is kept at its standard
// indices (config = 3, dump = 4) and sees the score tail as an ordinary index-4 byte stream: this wrapper
//   - serialises each 16-bit HPS word into two byte writes (low byte at the even address, as MAME/HPS order),
//   - removes the 128-byte EEPROM prefix from the byte address (tail byte 0 = file byte 128),
//   - on upload returns the tail words from the donor dump buffer (two byte reads per word, pipelined),
//   - rejects an all-zero or incomplete tail at the end of the download (the donor would otherwise write zeros
//     over the game's table after the first start/end check passed),
//   - sequences the OSD-open autosave: if the donor will upload (changed scores) that upload already carries the
//     EEPROM prefix; otherwise a plain upload request is issued after the donor finished (EEPROM-only changes).
`default_nettype wire
module ah_hiscore #(
    parameter integer EE_BYTES = 128,           // EEPROM prefix of the nvram file
    parameter integer HS_BYTES = 40             // score table length (must equal the MRA config entry length)
)(
    input         clk,
    input         rst,                          // game reset (high during every HPS download)
    input         cpu_paused,                   // from ah_main: 68000 frozen
    input         v_sync,                       // active high, one rising edge per frame
    input         osd_status,                   // OSD open
    input         autosave,                     // option "autosave on"
    // HPS (hps_io, WIDE = 1: ioctl_addr counts bytes in steps of 2)
    input         ioctl_download, ioctl_upload, ioctl_wr,
    input   [7:0] ioctl_index,
    input  [26:0] ioctl_addr,
    input  [15:0] ioctl_dout,
    output reg [15:0] tail_din,                 // upload data for byte addresses >= EE_BYTES (valid ~6 clk after the address)
    output        upload_req,                   // to hps_io ioctl_upload_req (nvram index 4)
    // game work RAM port (ah_main)
    output        hs_pause,                     // -> ah_main.hs_pause_req
    output [15:0] ram_addr,
    output  [7:0] ram_din,                      // data to write
    input   [7:0] ram_dout,
    output        ram_rd, ram_wr,
    input         ram_ready,
    output        configured
);
localparam [7:0] IDX_CFG = 8'd3, IDX_DUMP = 8'd4;
localparam [26:0] LAST_WORD = EE_BYTES + HS_BYTES - 2;

wire cfg_idx  = ioctl_index == IDX_CFG;
wire nv_idx   = ioctl_index == IDX_DUMP;
wire in_tail  = ioctl_addr >= EE_BYTES;
wire [24:0] tail_base = ioctl_addr[24:0] - EE_BYTES;

// ---------------------------------------------------------------- download: 16-bit word -> two byte writes
reg        h_wr = 1'b0, hi_pend = 1'b0;
reg [24:0] h_addr = 25'd0, hi_addr = 25'd0;
reg  [7:0] h_data = 8'd0, hi_data = 8'd0;
reg        nz = 1'b0, got_last = 1'b0, dl_q = 1'b0;
always @(posedge clk) begin
    h_wr <= 1'b0;
    dl_q <= ioctl_download;
    if (ioctl_download && !dl_q) begin nz <= 1'b0; got_last <= 1'b0; end
    if (hi_pend) begin
        h_wr <= 1'b1; h_addr <= hi_addr; h_data <= hi_data; hi_pend <= 1'b0;
    end else if (ioctl_download && ioctl_wr && (cfg_idx || (nv_idx && in_tail))) begin
        h_wr <= 1'b1; h_data <= ioctl_dout[7:0];
        h_addr <= nv_idx ? tail_base : ioctl_addr[24:0];
        hi_pend <= 1'b1; hi_data <= ioctl_dout[15:8];
        hi_addr <= (nv_idx ? tail_base : ioctl_addr[24:0]) + 25'd1;
        if (nv_idx) begin
            if (ioctl_dout != 16'd0) nz <= 1'b1;
            if (ioctl_addr == LAST_WORD) got_last <= 1'b1;
        end
    end
end
wire tail_ok = nz && got_last;

// The donor evaluates "dump downloaded" at the falling edge of ioctl_download from the index of the previous
// clk.  Delay download/index/data by 3 clk and force a non-dump index in the last delayed clks when the tail
// was empty/incomplete (validity is known as soon as the undelayed download ends).
reg [2:0] dl_sh = 3'd0;
reg [7:0] idx_d0, idx_d1, idx_d2;
always @(posedge clk) begin
    dl_sh <= {dl_sh[1:0], ioctl_download};
    idx_d0 <= ioctl_index; idx_d1 <= idx_d0; idx_d2 <= idx_d1;
end
wire       v_download = dl_sh[2];
wire       bad_end    = !ioctl_download && !tail_ok;
wire [7:0] v_index    = (idx_d2 == IDX_DUMP && bad_end) ? 8'hFE : idx_d2;

// ---------------------------------------------------------------- upload: two pipelined byte reads per word
reg        up_ph = 1'b0;
reg [24:0] h_addr_up = 25'd0;
reg  [7:0] up_lo = 8'd0;
wire [7:0] data_to_hps;
always @(posedge clk) begin
    up_ph <= ~up_ph;
    h_addr_up <= tail_base + {24'd0, up_ph};
    // data_to_hps lags h_addr_up by 2 clk and up_ph is inverted again by then: up_ph==1 -> low byte arrives
    if (ioctl_upload) begin
        if (up_ph) up_lo <= data_to_hps;
        else tail_din <= configured ? {data_to_hps, up_lo} : 16'd0;   // unconfigured: never publish buffer garbage
    end
end

wire [24:0] v_addr = ioctl_upload ? h_addr_up : h_addr;

// ---------------------------------------------------------------- donor
wire hs_up_req;
wire [15:0] ram_addr_w;
hiscore #(
    .HS_ADDRESSWIDTH(16), .HS_SCOREWIDTH(8), .HS_CONFIGINDEX(3), .HS_DUMPINDEX(4),
    .CFG_ADDRESSWIDTH(4), .CFG_LENGTHWIDTH(1)
) hi (
    .clk(clk), .paused(cpu_paused), .reset(rst), .autosave(autosave),
    .ioctl_upload(ioctl_upload), .data_ready(ram_ready), .ioctl_upload_req(hs_up_req),
    .ioctl_download(v_download), .ioctl_wr(h_wr), .ioctl_addr(v_addr), .ioctl_index(ioctl_upload ? ioctl_index : v_index),
    .OSD_STATUS(osd_status), .v_sync(v_sync),
    .data_from_hps(h_data), .data_from_ram(ram_dout),
    .ram_address(ram_addr_w), .data_to_hps(data_to_hps), .data_to_ram(ram_din),
    .ram_write(ram_wr), .ram_read(ram_rd), .ram_intent_read(), .ram_intent_write(),
    .pause_cpu(hs_pause), .configured(configured)
);
assign ram_addr = ram_addr_w;

// ---------------------------------------------------------------- OSD-open autosave sequencing
// hs_pause rises within a few clk of the OSD edge when the donor starts its extraction.  If it never does
// (no config, restore pending) or finishes without requesting an upload (scores unchanged), the EEPROM is
// still saved by a plain upload request.
reg        osd_q = 1'b0;
reg  [2:0] es = 3'd0;
reg [11:0] tmo = 12'd0;
reg  [3:0] ee_pulse = 4'd0;
always @(posedge clk) begin
    osd_q <= osd_status;
    if (ee_pulse != 0) ee_pulse <= ee_pulse - 4'd1;
    if (rst) es <= 3'd0;
    else case (es)
        3'd0: if (osd_status && !osd_q && autosave && !ioctl_download) begin
                  if (!configured) ee_pulse <= 4'd8;
                  else begin es <= 3'd1; tmo <= 12'd0; end
              end
        3'd1: begin                                   // wait for the donor to start extracting
                  tmo <= tmo + 12'd1;
                  if (hs_pause) es <= 3'd2;
                  else if (&tmo) begin ee_pulse <= 4'd8; es <= 3'd0; end
              end
        3'd2: if (!hs_pause) begin es <= 3'd3; tmo <= 12'd0; end   // extraction finished
        3'd3: begin                                   // donor upload request (changed scores) follows within ~60 clk
                  tmo <= tmo + 12'd1;
                  if (hs_up_req) es <= 3'd0;
                  else if (tmo[9]) begin ee_pulse <= 4'd8; es <= 3'd0; end
              end
        default: es <= 3'd0;
    endcase
end
assign upload_req = hs_up_req | (ee_pulse != 0);
endmodule
