`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input cen1p5, cen3, cen6, // 6000000 = 48000000*1/8 Hz 

    // Audio channels
    
    output signed [15:0] opn,
    output signed [15:0] opl,
    output [ 9:0] psg,
    output signed [13:0] pcm,
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
`ifdef JTFRAME_SDRAM_XL
    output reg [23:0] post_addr,
`elsif JTFRAME_SDRAM_LARGE
    output reg [22:0] post_addr,
`else
    output reg [21:0] post_addr,
`endif

    output reg [ 7:0] post_data,

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
    output   [1:0] dsn,
    output   [15:0] main_dout,
    // Buses to BRAM

    // Buses to SDRAM
    input    [15:0] ram_data,
    output          ram_cs,
    output   [15:1] ram_addr,
    output          ram_we,
    input           ram_ok,

    input    [15:0] ba2mcu_data,
    output          ba2mcu_cs,
    output   [13:1] ba2mcu_addr,
    output          ba2mcu_we,
    output   [15:0] ba2mcu_din,
    output   [ 1:0] ba2mcu_dsn,
    input           ba2mcu_ok,

    input    [15:0] b0ram_data,
    output          b0ram_cs,
    output   [13:1] b0ram_addr,
    input           b0ram_ok,

    input    [15:0] b1ram_data,
    output          b1ram_cs,
    output   [13:1] b1ram_addr,
    input           b1ram_ok,

    input    [15:0] b2ram_data,
    output          b2ram_cs,
    output   [13:1] b2ram_addr,
    input           b2ram_ok,

    input    [15:0] main_data,
    output          main_cs,
    output   [18:1] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [15:0] snd_addr,
    input           snd_ok,

    input    [ 7:0] adpcm_data,
    output          adpcm_cs,
    output   [17:0] adpcm_addr,
    input           adpcm_ok,

    input    [31:0] b0rom_data,
    output          b0rom_cs,
    output   [18:2] b0rom_addr,
    input           b0rom_ok,

    input    [31:0] b1rom_data,
    output          b1rom_cs,
    output   [18:2] b1rom_addr,
    input           b1rom_ok,

    input    [31:0] b2rom_data,
    output          b2rom_cs,
    output   [18:2] b2rom_addr,
    input           b2rom_ok,

    input    [31:0] obj_data,
    output          obj_cs,
    output   [18:2] obj_addr,
    input           obj_ok,

    input    [ 7:0] mcu_data,
    output          mcu_cs,
    output   [15:0] mcu_addr,
    input           mcu_ok
