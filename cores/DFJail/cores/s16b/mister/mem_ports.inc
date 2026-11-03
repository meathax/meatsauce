`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen_fm, // 3999999 = 50347216*4562/57421 Hz 
    input cen_fm2, // 1999999 = 50347216*2281/57421 Hz 
    input cen_nc1, cen_snd, // 7999999 = 50347216*9124/57421 Hz 
    input cen_nc2, cen6, // 5999999 = 50347216*6843/57421 Hz 
    input cen_nc3, cen_pcm, // 639999 = 50347216*388/30523 Hz 

    // Audio channels
    output mute,
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
    output   [13:1] nvram_addr,
    output   [15:0] nvram_din,
    input   [15:0] nvram_dout,
    output   [1:0] nvram_we,
    input   [15:0] wram_dout,
    output    dfjail_analog_reset,
    output    gfx_cs,
    // Buses to BRAM

    output   [ 1:0] wram_we, // Dual port for wram
    
    // Buses to SDRAM
    input    [15:0] xram_data,
    output          xram_cs,
    output   [18:1] xram_addr,
    output          xram_we,
    output   [15:0] xram_din,
    output   [ 1:0] xram_dsn,
    input           xram_ok,

    input    [15:0] main_data,
    output          main_cs,
    output   [18:1] main_addr,
    input           main_ok,

    input    [15:0] map1_data,
    output   [15:1] map1_addr,
    input           map1_ok,

    input    [15:0] map2_data,
    output   [15:1] map2_addr,
    input           map2_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [18:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] pcm_data,
    output          pcm_cs,
    output   [16:0] pcm_addr,
    input           pcm_ok,

    input    [31:0] char_data,
    output   [19:2] char_addr,
    input           char_ok,

    input    [31:0] scr1_data,
    output   [19:2] scr1_addr,
    input           scr1_ok,

    input    [31:0] scr2_data,
    output   [19:2] scr2_addr,
    input           scr2_ok,

    input    [15:0] obj_data,
    output          obj_cs,
    output   [20:1] obj_addr,
    input           obj_ok
