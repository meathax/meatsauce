`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen8, // 8000000 = 48000000*1/6 Hz 
    input cen_pcm, // 16000000 = 48000000*1/3 Hz 

    // Audio channels
    output mute,
    
    output signed [15:0] pcm_4k,
    output signed [15:0] pcm_8k,
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
    output   [15:0] cpu_dout,
    input   [15:0] ram_dout,
    input   [15:0] tlv_dout,
    output   [13:1] tlrd_addr,
    output   [9:1] palrd_addr,
    input   [15:0] pal_data,
    output   [12:1] code_addr,
    input   [15:0] nvram_dout,
    output   [1:0] ram_we,
    input   [15:0] tlrd_data,
    output   [1:0] pal_we,
    output   [16:1] ram_addr,
    input   [7:0] yram_dout,
    output    yram_we,
    input   [7:0] col_data,
    output   [15:0] dma_din,
    input   [15:0] dma_dout,
    input   [15:0] code_dout,
    output   [1:0] tlv_we,
    input   [15:0] pal_dout,
    output   [9:0] col_addr,
    output   [12:1] dma_addr,
    output   [1:0] dma_we,
    output   [1:0] nvram_we,
    // Buses to BRAM

    
    
    
    
    
    
    // Buses to SDRAM
    input    [15:0] main_data,
    output          main_cs,
    output   [19:1] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [17:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] pcm_data,
    output          pcm_cs,
    output   [19:0] pcm_addr,
    input           pcm_ok,

    input    [31:0] tile_data,
    output          tile_cs,
    output   [20:2] tile_addr,
    input           tile_ok,

    input    [31:0] scr_data,
    output          scr_cs,
    output   [20:2] scr_addr,
    input           scr_ok,

    input    [31:0] obj_data,
    output          obj_cs,
    output   [20:2] obj_addr,
    input           obj_ok
