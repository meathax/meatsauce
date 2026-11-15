`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen_16, // 16000000 = 48000000*1/3 Hz 
    input cen_8, // 8000000 = 48000000*1/6 Hz 
    input cen_pcm, // 18432000 = 48000000*48/125 Hz 

    // Audio channels
    output signed [15:0] pcm0_l,
    output signed [15:0] pcm0_r,output signed [15:0] pcm1_l,
    output signed [15:0] pcm1_r,
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
    output   [7:0] nvram_din,
    input   [7:0] nvram_dout,
    output    nvram_we,
    output   [7:1] hscore_addr,
    output   [6:0] nvseed_addr,
    output   [16:1] vram_addr,
    input   [15:0] pall_dout,
    output   [11:1] cpall_addr,
    output   [15:0] cpu_dout,
    output   [15:0] wram_din,
    output   [1:0] wram_we,
    input   [15:0] hscore_dout,
    input   [7:0] nvseed_data,
    output   [11:1] palh_addr,
    output   [11:1] cpalh_addr,
    input   [15:0] cpalh_dout,
    output   [6:0] nvram_addr,
    output   [15:0] hscore_din,
    input   [15:0] vram_dout,
    output   [16:1] vmem_addr,
    input   [15:0] vmem_dout,
    input   [15:0] palh_dout,
    input   [15:0] cpall_dout,
    output   [15:1] wram_addr,
    input   [15:0] wram_dout,
    output   [1:0] hscore_we,
    output   [11:1] pall_addr,
    // Buses to BRAM

    
    
    
    
    output   [ 1:0] vmem_we, // Dual port for vmem
    
    output   [ 1:0] cpalh_we, // Dual port for cpalh
    
    output   [ 1:0] cpall_we, // Dual port for cpall
    
    // Buses to SDRAM
    input    [15:0] main_data,
    output          main_cs,
    output   [21:1] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [17:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] pcma_data,
    output          pcma_cs,
    output   [21:0] pcma_addr,
    input           pcma_ok,

    input    [ 7:0] pcmb_data,
    output          pcmb_cs,
    output   [21:0] pcmb_addr,
    input           pcmb_ok,

    input    [31:0] rozchar_data,
    output          rozchar_cs,
    output   [20:2] rozchar_addr,
    input           rozchar_ok,

    input    [ 7:0] rozmap_data,
    output          rozmap_cs,
    output   [19:0] rozmap_addr,
    input           rozmap_ok,

    input    [31:0] tile_data,
    output          tile_cs,
    output   [22:2] tile_addr,
    input           tile_ok,

    input    [31:0] obj_data,
    output          obj_cs,
    output   [22:2] obj_addr,
    input           obj_ok
