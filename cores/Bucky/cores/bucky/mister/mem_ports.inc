`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen_2, cen_4, cen_8, cen_16, // 16000000 = 48000000*1/3 Hz 
    input cen_pcm, // 18432000 = 48000000*48/125 Hz 

    // Audio channels
    output signed [15:0] fm_l,
    output signed [15:0] fm_r,output signed [15:0] pcm_l,
    output signed [15:0] pcm_r,
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
    output    nvram_we,
    output   [6:0] nvram_addr,
    output   [7:0] nvram_din,
    input   [7:0] nvram_dout,
    // Buses to BRAM

    
    // Buses to SDRAM
    input    [15:0] ram_data,
    output          ram_cs,
    output   [17:1] ram_addr,
    output          ram_we,
    output   [15:0] ram_din,
    output   [ 1:0] ram_dsn,
    input           ram_ok,

    input    [15:0] main_data,
    output          main_cs,
    output   [21:1] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [17:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] pcm_data,
    output          pcm_cs,
    output   [21:0] pcm_addr,
    input           pcm_ok,

    input    [31:0] scr_data,
    output          scr_cs,
    output   [20:2] scr_addr,
    input           scr_ok,

    input    [31:0] lyro_data,
    output          lyro_cs,
    output   [22:2] lyro_addr,
    input           lyro_ok
