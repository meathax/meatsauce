`timescale 1ns/1ps
`default_nettype none

// Latch CMOS dirtiness and request one MiSTer upload when the OSD is opened.
// This follows the established MiSTer NVRAM contract: game writes only mark the
// image dirty; opening the OSD takes a stable snapshot.  A request is held for
// the complete upload and cannot re-arm until a later OSD-open edge.
module narc_nvram_dirty (
  input  wire clk,
  input  wire rst,
  input  wire core_cmos_write,
  input  wire restore_active,
  input  wire upload_active,
  input  wire osd_status,
  output logic modified
);
  logic upload_active_q;
  logic osd_status_q;
  logic dirty;

  always_ff @(posedge clk) begin
    if (rst) begin
      modified        <= 1'b0;
      upload_active_q <= 1'b0;
      osd_status_q    <= 1'b0;
      dirty           <= 1'b0;
    end else begin
      upload_active_q <= upload_active;
      osd_status_q    <= osd_status;

      if (restore_active) begin
        modified <= 1'b0;
        dirty    <= 1'b0;
      end else begin
        if (core_cmos_write)
          dirty <= 1'b1;

        // A falling upload edge completes this OSD session's snapshot. CMOS is
        // transactionally quiescent during upload, so no game write is lost.
        if (upload_active_q && !upload_active) begin
          modified <= 1'b0;
          dirty    <= 1'b0;
        end else if (!osd_status_q && osd_status &&
                     (dirty || core_cmos_write) && !modified) begin
          modified <= 1'b1;
        end
      end
    end
  end
endmodule

`default_nettype wire
