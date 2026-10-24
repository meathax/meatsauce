`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cpu_cen, // 3072115 = 49153840*1/16 Hz 
    input psg_cen, mcpu_cen, // 3579545 = 49153840*455/6248 Hz 
    input tms_cen, // 649200 = 49153840*739/55953 Hz 
    input mix_cen, // 192000 = 49153840*209/53506 Hz 

    // Audio channels
    
    output signed [15:0] music,
    output signed [15:0] voice,
    output signed [15:0] pcm,
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
    output   [7:0] objram_v_addr,
    output   [8:0] pal9g_addr,
    input   [3:0] pal9f_data,
    input   [7:0] vram_dout,
    output   [5:0] attr_addr,
    input   [7:0] attr_v_dout,
    output   [7:0] objram_din,
    input   [7:0] objram_dout,
    output   [7:0] wram_din,
    input   [7:0] wram_dout,
    output   [10:0] vram_v_addr,
    output   [7:0] objram_addr,
    input   [7:0] objram_v_dout,
    input   [3:0] pal9g_data,
    output   [10:0] wram_addr,
    output   [10:0] vram_addr,
    output   [7:0] vram_din,
    output    vram_we,
    output   [7:0] attr_din,
    output    attr_we,
    output    objram_we,
    output   [8:0] pal9f_addr,
    output    wram_we,
    input   [7:0] vram_v_dout,
    input   [7:0] attr_dout,
    output   [5:0] attr_v_addr,
    // Buses to BRAM

    
    
    
    
    
    
    // Buses to SDRAM
    input    [ 7:0] main_data,
    output          main_cs,
    output   [15:0] main_addr,
    input           main_ok,

    input    [ 7:0] melody_data,
    output          melody_cs,
    output   [13:0] melody_addr,
    input           melody_ok,

    input    [ 7:0] speech_data,
    output          speech_cs,
    output   [13:0] speech_addr,
    input           speech_ok,

    input    [31:0] scr_data,
    output          scr_cs,
    output   [14:2] scr_addr,
    input           scr_ok,

    input    [31:0] objgfx_data,
    output          objgfx_cs,
    output   [14:2] objgfx_addr,
    input           objgfx_ok
