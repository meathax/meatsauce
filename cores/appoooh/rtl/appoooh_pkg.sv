// SPDX-License-Identifier: GPL-3.0-or-later
// Appoooh packed ROM stream: fixed CPU ROM, two banks, six graphics planes,
// populated ADPCM ROMs, palette PROM, and two lookup PROMs.
package appoooh_pkg;
 localparam integer ROM_MAINCPU_BASE=0, ROM_MAINCPU_SIZE='h12000;
 localparam integer ROM_GFX1_BASE='h12000, ROM_GFX1_SIZE='h0c000;
 localparam integer ROM_GFX2_BASE='h1e000, ROM_GFX2_SIZE='h0c000;
 localparam integer ROM_ADPCM_BASE='h2a000, ROM_ADPCM_SIZE='h0a000;
 localparam integer ROM_PROMS_BASE='h34000, ROM_PROMS_SIZE='h00220;
 localparam integer ROM_SIZE='h34220;
 // Robo Wres packs its three 32 KiB graphics ROMs per set and one 32 KiB
 // sample ROM after the 24 KiB CPU payload.
 localparam integer ROBOWRES_MAINCPU_BASE=0, ROBOWRES_MAINCPU_SIZE='h18000;
 localparam integer ROBOWRES_GFX1_BASE='h18000, ROBOWRES_GFX1_SIZE='h18000;
 localparam integer ROBOWRES_GFX2_BASE='h30000, ROBOWRES_GFX2_SIZE='h18000;
 localparam integer ROBOWRES_ADPCM_BASE='h48000, ROBOWRES_ADPCM_SIZE='h08000;
 localparam integer ROBOWRES_PROMS_BASE='h50000, ROBOWRES_PROMS_SIZE='h00220;
 localparam integer ROBOWRES_ROM_SIZE='h50220;
 localparam logic [7:0] DIP1_DEFAULT=8'h60, DIP2_DEFAULT=8'hff;
endpackage
