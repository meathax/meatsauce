// Single source of truth for the Steel Force / Mortal Race display raster.
// Included inside a module body by steel_raster.sv, steel_timing.sv and anything that must agree
// with the raster totals (a future crt_adjust must take HTOTAL/VTOTAL from here: mister-video-output.md rule 10).
//
// APPROXIMATION, NOT A MEASURED PCB RASTER. MAME's stlforce.cpp uses set_refresh_hz(58) +
// set_size(512,256) ("vblank not accurate"), which is a bitmap size; no Electronic Devices
// sibling driver (mwarr, stlforce, diverboy, mugsmash, pzletime) has set_raw, and no PCB document
// gives the crystal divider. The totals below are a standard CRT-lockable 15 kHz raster:
//   pixel clock 45.6 MHz / 6 = 7.6 MHz (even, integer divider)
//   500 pixels * 262 lines  -> 15.200 kHz line rate, 58.015 Hz (786,000 clocks/frame, +0.026 % on 58 Hz)
// Visible window is the captured 366 x 240 (x 8..373 of the old 512-wide bitmap).
// Horizontal: 8 px back porch tail, 366 active, 18 px front porch, 36 px HS (4.74 us), 72 px back porch.
// Vertical: 240 active, 4 front porch lines, 3 VS lines starting at the HS leading edge, 15 back porch lines.
localparam integer RASTER_PIXEL_DIV     = 6;
localparam integer RASTER_HTOTAL        = 500;
localparam integer RASTER_VTOTAL        = 262;
localparam integer RASTER_H_ACTIVE_FIRST= 8;
localparam integer RASTER_H_ACTIVE      = 366;
localparam integer RASTER_V_ACTIVE      = 240;
localparam integer RASTER_HS_START      = 392;
localparam integer RASTER_HS_WIDTH      = 36;
localparam integer RASTER_VS_LINE       = 244;
localparam integer RASTER_VS_LINES      = 3;
localparam integer RASTER_LINE_CLOCKS   = RASTER_HTOTAL * RASTER_PIXEL_DIV;
localparam integer RASTER_FRAME_CLOCKS  = RASTER_LINE_CLOCKS * RASTER_VTOTAL;
