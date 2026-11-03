// One NVRAM save request per OSD opening.
//
// Main_MiSTer polls the core's latched save request at every OSD menu step.
// hps_io latches one request per rising edge of ioctl_upload_req and clears it
// when the menu reads it. This gate raises that request only while the OSD has
// been closed for CLOSED_HOLD clocks, so the latch is already pending when the
// OSD opens (one save at the opening) and no new edge can occur while the user
// navigates pages or directories. A new request is possible only after the OSD
// has opened and closed again.
module daikaiju_save_gate #(
    parameter integer CLOSED_HOLD = 48_000_000   // 1 s at 48 MHz
) (
    input  logic clk_sys,
    input  logic reset,
    input  logic osd_open,
    input  logic want_save,      // score changed and hiscore state ready
    input  logic upload_active,  // HPS is transferring the NVRAM image
    output logic upload_req
);
    localparam integer CW = $clog2(CLOSED_HOLD + 1);
    logic [CW-1:0] closed_cnt = '0;
    logic spent = 1'b0;
    wire closed_full = (closed_cnt == CLOSED_HOLD[CW-1:0]);

    always_ff @(posedge clk_sys) begin
        if (reset || osd_open) closed_cnt <= '0;
        else if (!closed_full) closed_cnt <= closed_cnt + 1'b1;

        if (reset) begin
            upload_req <= 1'b0;
            spent <= 1'b0;
        end else begin
            if (osd_open) spent <= 1'b0;
            if (closed_full && want_save && !spent && !upload_req) begin
                upload_req <= 1'b1;
                spent <= 1'b1;
            end else if (upload_active || !want_save) begin
                upload_req <= 1'b0;
            end
        end
    end
endmodule
