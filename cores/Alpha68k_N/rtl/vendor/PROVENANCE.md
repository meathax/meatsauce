# CPU provenance

Sources come from the revisions in `provenance.json`.
fx68k: https://github.com/ijor/fx68k . T80 generated Verilog: https://github.com/jotego/jtcores/tree/548b87b32a1b528a16cb41f689accb179e85d1a8/modules/jtframe/hdl/cpu/t80 .
Retain source license headers and the copied repository license files. T80s contains its generated dependency closure in one file; its VHDL-origin notices are retained.
fx68k.sv has only three signal structs changed to packed. Independent continuous/NBA member drivers otherwise trigger BLKANDNBLK in Verilator 5.050. Logic and microcode are unchanged. The adapted source is shared by simulation and synthesis; original/imported hashes are retained.
