// SPDX-License-Identifier: GPL-3.0-or-later
// Shared platform/unit wiring: the real EEPROM memory remains behind u_dump.
module gaiapolis_mister_nvram_boundary #(
    parameter integer FILE_BYTES=128,
    parameter integer LEGACY_BYTES=128
)(
    input logic clk,cold_reset,
    input logic hps_download,hps_upload,hps_rd,
    input logic [15:0] hps_index,
    input logic transport_wr,transport_ram,
    input logic [26:0] transport_addr,
    input logic [7:0] transport_dout,ioctl_din,
    input logic sav_wait,sav_change,autosave,osd_open,
    output logic [26:0] ioctl_addr,
    output logic [7:0] ioctl_dout,hps_din,
    output logic ioctl_ram,ioctl_wr,hps_wait,sav_ack,
    output logic [1:0] sav_wr,
    output logic upload_req,restore_complete,upload_complete,transfer_error
);
    wire [26:0] nv_addr;
    wire [7:0] nv_data;
    wire nv_ram,nv_wr,nv_restore;
    gaiapolis_mister_nvram_guard #(.FILE_BYTES(FILE_BYTES),.LEGACY_BYTES(LEGACY_BYTES)) u_guard(
        .clk(clk),.cold_reset(cold_reset),.raw_download(hps_download),.raw_upload(hps_upload),
        .raw_wr(transport_wr),.raw_rd(hps_rd),.raw_index(hps_index),.raw_addr(transport_addr),
        .raw_dout(transport_dout),.game_din(ioctl_din),.safe_wait(sav_wait),.serial_commit(sav_change),
        .autosave(autosave),.osd_open(osd_open),.host_din(hps_din),.game_dout(nv_data),.game_addr(nv_addr),
        .game_ram(nv_ram),.game_wr(nv_wr),.host_wait(hps_wait),.freeze_req(sav_ack),
        .restore_pending(nv_restore),.upload_req(upload_req),.restore_complete(restore_complete),
        .upload_complete(upload_complete),.transfer_error(transfer_error)
    );
    always_comb begin
        ioctl_ram = nv_ram || (hps_index!=16'd2 && !sav_ack && transport_ram);
        ioctl_addr = nv_ram ? nv_addr : transport_addr;
        ioctl_dout = nv_ram ? nv_data : transport_dout;
        ioctl_wr = nv_ram ? nv_wr : (hps_index!=16'd2 && !sav_ack && transport_wr);
        // Direction only. NV bytes are delivered through actual IOCTL/u_dump.
        sav_wr = {1'b0,nv_restore};
    end
endmodule
