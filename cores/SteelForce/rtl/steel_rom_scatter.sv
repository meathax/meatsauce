// Steel Force family raw MRA image -> native packed-row storage.
// Address permutation only; bytes are unchanged. See ROM_DOWNLOAD.md.
module steel_rom_scatter(
    input wire mortalr,
    input wire [22:0] source_addr,
    output wire [22:0] storage_addr
);
    wire tile=source_addr>=23'h100000 &&
        source_addr<(mortalr ? 23'h400000 : 23'h280000);
    wire sprite=source_addr>=23'h400000 &&
        source_addr<(mortalr ? 23'h600000 : 23'h500000);
    assign storage_addr=tile ? {source_addr[22:7],source_addr[5:2],source_addr[6],source_addr[1:0]} :
        sprite ? (mortalr ? {2'b10,source_addr[18:5],source_addr[3:0],source_addr[20:19],~source_addr[4]} :
            {3'b100,source_addr[17:5],source_addr[3:0],source_addr[19:18],~source_addr[4]}) :
        source_addr;
endmodule
