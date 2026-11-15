`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cpu_cen, // 3071732 = 49147720*1/16 Hz 
    input audio_cen, // 1535866 = 49147720*1/32 Hz 

    // Audio channels
    
    output [15:0] psg_snd,
    output psg_snd_rcen,
    output [15:0] dac_snd,
    output dac_snd_rcen,
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
    input   [7:0] videoram_dout,
    output   [9:0] tile_vram_addr,
    output    spriteram0_we,
    output   [4:0] obj_ram1_addr,
    input   [7:0] obj_ram1_data,
    input   [7:0] nvram_dout,
    output    nvram_we,
    output   [7:0] sharedram_din,
    input   [7:0] mcu_sharedram_dout,
    output   [7:0] videoram_din,
    output    videoram_we,
    input   [7:0] obj_ram0_data,
    output    row_scroll_we,
    output   [7:0] nvram_din,
    output    sharedram_we,
    output   [7:0] mcu_sharedram_din,
    input   [7:0] tile_color_data,
    output   [6:0] spriteram0_addr,
    output   [7:0] spriteram1_din,
    input   [7:0] scroll_video_data,
    output   [5:0] proms_addr,
    output   [10:0] sharedram_addr,
    input   [7:0] colorram_dout,
    output   [4:0] scroll_video_addr,
    input   [7:0] tile_vram_data,
    output   [7:0] nvram_addr,
    output   [10:0] mcu_sharedram_addr,
    output   [7:0] colorram_din,
    output    colorram_we,
    output   [8:0] tile_color_addr,
    output   [6:0] obj_ram0_addr,
    output   [4:0] spriteram1_addr,
    output   [4:0] row_scroll_addr,
    input   [7:0] sharedram_dout,
    output   [8:0] colorram_addr,
    output   [7:0] spriteram0_din,
    input   [7:0] spriteram0_dout,
    input   [7:0] spriteram1_dout,
    output    spriteram1_we,
    output   [7:0] row_scroll_din,
    input   [7:0] row_scroll_dout,
    input   [7:0] proms_data,
    output    mcu_sharedram_we,
    output   [9:0] videoram_addr,
    // Buses to BRAM

    
    
    
    
    
    
    
    
    // Buses to SDRAM
    input    [ 7:0] maincpu_data,
    output          maincpu_cs,
    output   [14:0] maincpu_addr,
    input           maincpu_ok,

    input    [ 7:0] mcu_data,
    output          mcu_cs,
    output   [14:0] mcu_addr,
    input           mcu_ok,

    input    [15:0] scr_data,
    output          scr_cs,
    output   [13:1] scr_addr,
    input           scr_ok,

    input    [15:0] obj_data,
    output          obj_cs,
    output   [13:1] obj_addr,
    input           obj_ok
