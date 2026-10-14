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
    output   [16:1] wram_addr,
    output   [7:0] nvram_din,
    input   [15:0] hs_dout,
    input   [15:0] cpall_dout,
    output   [16:1] vram_addr,
    input   [15:0] objram_dout,
    input   [15:0] omem_dout,
    output   [1:0] wram_we,
    output   [6:0] nvram_addr,
    input   [15:0] vram_dout,
    output   [11:1] palh_addr,
    input   [15:0] palh_dout,
    input   [15:0] cpalh_dout,
    output   [15:0] cpu_dout,
    output   [15:0] wram_din,
    input   [7:0] nvram_dout,
    input   [15:0] pall_dout,
    input   [15:0] wram_dout,
    output   [16:1] vmem_addr,
    output   [8:1] hs_addr,
    output   [15:0] hs_din,
    output   [1:0] hs_we,
    output   [11:1] cpall_addr,
    output    nvram_we,
    output   [11:1] cpalh_addr,
    output   [10:1] objram_addr,
    output   [10:1] omem_addr,
    input   [15:0] vmem_dout,
    output   [11:1] pall_addr,
    // Buses to BRAM

    
    
    output   [ 1:0] vmem_we, // Dual port for vmem
    
    
    output   [ 1:0] cpalh_we, // Dual port for cpalh
    
    output   [ 1:0] cpall_we, // Dual port for cpall
    
    output   [ 1:0] omem_we, // Dual port for omem
    
    // Buses to SDRAM
    input    [15:0] main_data,
    output          main_cs,
    output   [20:1] main_addr,
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

    input    [31:0] tile_data,
    output          tile_cs,
    output   [21:2] tile_addr,
    input           tile_ok,

    input    [31:0] obj_data,
    output          obj_cs,
    output   [22:2] obj_addr,
    input           obj_ok,
    // Metamorphic Force K053250 ROM channels; widths from current wrapper.
    input [31:0] lvc0_data,lvc1_data,
    output lvc0_cs,lvc1_cs,
    output [17:2] lvc0_addr,lvc1_addr,
    input lvc0_ok,lvc1_ok
