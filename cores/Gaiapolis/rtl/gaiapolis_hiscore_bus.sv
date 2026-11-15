// SPDX-License-Identifier: GPL-3.0-or-later
// clk48 caller adaptation for the clk96 work/shadow BRAM ports.
// One accepted CPU event per AS write cycle; held restore requests drain before
// ownership returns to the CPU. File ownership inhibits only new restorations.
module gaiapolis_hiscore_bus(
    input wire monster,
    input wire clk,rst,restore_inhibit,pause_safe,
    input wire cpu_ram_selected,cpu_bus_write,cpu_ram_ready,
    input wire [23:1] cpu_addr,
    input wire [15:0] cpu_data,
    input wire [1:0] cpu_we,
    output wire [14:0] wram_addr,
    output wire [15:0] wram_data,
    output wire [1:0] wram_we,
    output wire [6:0] hs_addr,
    output wire [15:0] hs_data,
    output wire [1:0] hs_we,
    input wire [15:0] hs_dout,
    output wire pause_request,boot_ready,hs_dirty,
    output wire shadow_valid,table_initialized,boundary_fault,
    output wire [7:0] restored_words,
    output wire cpu_commit,restore_owns_ram,
    output wire [12:0] restore_row,
    output wire [2:0] restore_lane
);
    reg commit_seen,ram_ack_q,collision;
    wire cpu_write=cpu_ram_selected&&cpu_bus_write&&|cpu_we;
    wire [14:0] restore_addr;
    wire [15:0] restore_data;
    wire [1:0] restore_we;
    wire hs_fault;
    assign cpu_commit=cpu_write&&cpu_ram_ready&&!commit_seen&&!restore_owns_ram&&!rst;
    assign wram_addr=restore_owns_ram ? restore_addr : cpu_addr[15:1];
    assign wram_data=restore_owns_ram ? restore_data : cpu_data;
    assign wram_we=rst ? 2'b00 : restore_owns_ram ? restore_we :
                   cpu_write ? cpu_we : 2'b00;
    assign boundary_fault=hs_fault||collision;
    always @(posedge clk) begin
        if(rst) begin commit_seen<=1'b0;ram_ack_q<=1'b0;collision<=1'b0;end
        else begin
            if(!cpu_write) commit_seen<=1'b0;
            else if(cpu_commit) commit_seen<=1'b1;
            // At least two clk96 writes occur before this acknowledgement is
            // consumed on a subsequent clk48 edge. Repeat writes are identical.
            ram_ack_q<=restore_owns_ram;
            if(restore_owns_ram&&cpu_write) collision<=1'b1;
        end
    end
    gaiapolis_hiscore u_adapter(
        .monster(monster),
        .clk(clk),.rst(rst),.restore_inhibit(restore_inhibit),.cpu_commit(cpu_commit),
        .cpu_byte_addr({cpu_addr,1'b0}),.cpu_data(cpu_data),.cpu_byte_we(cpu_we),
        .pause_request(pause_request),.pause_safe(pause_safe),.ram_request(restore_owns_ram),
        .ram_addr(restore_addr),.ram_data(restore_data),.ram_we(restore_we),
        .ram_row(restore_row),.ram_lane(restore_lane),
        .ram_ack(ram_ack_q&&pause_safe&&restore_owns_ram),
        .hs_addr(hs_addr),.hs_data(hs_data),.hs_we(hs_we),.hs_dout(hs_dout),
        .hs_dirty(hs_dirty),.shadow_valid(shadow_valid),.table_initialized(table_initialized),
        .restored_words(restored_words),.boundary_fault(hs_fault),.boot_ready(boot_ready)
    );
endmodule
