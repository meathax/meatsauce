`timescale 1ns/1ps
`default_nettype none
// Centralized MiSTer run/reset policy. NVRAM upload is observational: it pauses
// the core while the shared SDRAM data port is owned by the uploader, but it
// never clears CPU, sound, video, or RAM state.
module narc_run_control (
  input  wire reset_ext,
  input  wire reset_menu,
  input  wire reset_button,
  input  wire pll_locked,
  input  wire ioctl_download,
  input  wire rom_loaded,
  input  wire nvram_active,
  input  wire pause_menu,
  output wire video_reset,
  output wire game_reset,
  output wire core_pause
);
  assign video_reset = reset_ext | reset_menu | reset_button | ~pll_locked;
  assign game_reset  = video_reset | ioctl_download | ~rom_loaded;
  assign core_pause  = pause_menu | nvram_active;
endmodule
`default_nettype wire
