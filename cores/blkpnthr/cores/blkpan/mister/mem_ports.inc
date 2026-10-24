`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    // Audio channels
    output signed [15:0] fm_l,
    output signed [15:0] fm_r,
    output signed [10:0] pcm,
    // Memory ports
`ifdef JTFRAME_SDRAM_XL
    input   [23:0]  prog_addr,
`elsif JTFRAME_SDRAM_LARGE
    input   [22:0]  prog_addr,
`else
    input   [21:0]  prog_addr,
`endif
    input   [ 7:0]  prog_data,
    input           prog_we,
    input   [ 1:0]  prog_ba,
`ifdef JTFRAME_SDRAM_XL
    input   [26:0]  ioctl_addr,
`else
    input   [25:0]  ioctl_addr,
`endif
    input           prom_we,
`ifdef JTFRAME_HEADER
    input           header,
`endif
`ifdef JTFRAME_IOCTL_RD
    input           ioctl_wr,
    output   [ 7:0] ioctl_din,
    input    [ 7:0] ioctl_dout, `endif
    input           ioctl_ram,
    input           ioctl_cart,
    // Explicit ports
    input   [15:0] palcpu_dout,
    output   [15:0] main_dout,
    output   [11:1] pal_addr,
    input   [15:0] pal_dout,
    output   [11:1] palcpu_addr,
    output   [1:0] palcpu_we,
    // Buses to BRAM

    
    // Buses to SDRAM
    input    [15:0] main_data,
    output          main_cs,
    output   [18:1] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [14:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] pcma_data,
    output          pcma_cs,
    output   [16:0] pcma_addr,
    input           pcma_ok,

    input    [ 7:0] pcmb_data,
    output          pcmb_cs,
    output   [16:0] pcmb_addr,
    input           pcmb_ok
