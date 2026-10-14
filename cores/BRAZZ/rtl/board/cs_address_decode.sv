// SPDX-License-Identifier: GPL-3.0-or-later
// CPU address map from the Crystal System driver. Offsets are byte addresses.
module cs_address_decode (
    input logic [31:0] address,
    input logic [2:0] flash_bank,
    output logic [3:0] target,
    output logic [31:0] offset
);
    always_comb begin
        target = 15; offset = address;
        // Disjoint apertures: compare only their significant prefix bits and
        // select in parallel, rather than chaining full-width range compares.
        unique case (1'b1)
            (address[31:17] == 15'h0000): begin target = 0; offset = address; end
            (address[31:24] == 8'h02): begin target = 1; offset = {9'b0,address[22:0]}; end
            (address[31:23] == 9'h007): begin target = 2; offset = {9'b0,address[22:0]}; end
            (address[31:23] == 9'h008): begin target = 3; offset = {9'b0,address[22:0]}; end
            (address[31:24] == 8'h05): begin target = 4; offset = {5'b0,flash_bank,address[23:0]}; end
            (address[31:16] == 16'h0140): begin target = 5; offset = {16'b0,address[15:0]}; end
            (address[31:23] == 9'h003): begin target = 6; offset = {9'b0,address[22:0]}; end
            (address[31:16] == 16'h0300): begin target = 7; offset = {16'b0,address[15:0]}; end
            (address[31:12] == 20'h04800): begin target = 8; offset = {20'b0,address[11:0]}; end
            (address[31:4] == 28'h0120000 && address[3:0] < 4'hc): begin target = 9; offset = {28'b0,address[3:0]}; end
            (address[31:2] == 30'h004a0000): begin target = 10; offset = {30'b0,address[1:0]}; end
            (address[31:2] == 30'h004c8000): begin target = 11; offset = {30'b0,address[1:0]}; end
            (address[31:6] == 26'h111053d && address[5:0] >= 6'h0c): begin target = 12; offset = {26'b0,(address[5:0]-6'h0c)}; end
            default: begin end
        endcase
    end
endmodule

// Transport-cache policy for CPU accesses. Work RAM (both mirrors) is cacheable
// for reads and write-through writes. The 128KiB BIOS and the normal-mode
// cartridge window are ROM: MAME ignores CPU writes there (BIOS nopw, window
// bankr read-only), so a write must bypass the cache and invalidate a hit rather
// than patch a cached ROM line. The first cartridge word is the flash command
// register and is never cached; every cartridge read bypasses while a non-FF
// command is selected. All I/O, SoC, video and sound spaces are uncached.
module cs_cache_policy (
    input logic [31:0] address,
    input logic write, flash_read_override,
    output logic cacheable
);
    always_comb cacheable = address[31:24]==8'h02 ||
        (!write && (address[31:17]==15'h0000 ||
            (address[31:24]==8'h05 && address!=32'h05000000 && !flash_read_override)));
endmodule
