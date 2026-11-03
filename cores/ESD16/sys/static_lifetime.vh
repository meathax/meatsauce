// Explicit simulator lifetime; Quartus17 retains its original implicit-static form.
`ifndef SWAT_LOCAL_STATIC
`ifdef VERILATOR
`define SWAT_LOCAL_STATIC static
`else
`define SWAT_LOCAL_STATIC
`endif
`endif
