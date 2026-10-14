# Integrating MeatCore Credits

Copy `credits/` and `credits.txt` together to the root of your existing core.
The untouched reference template is in `upstream/Template_MiSTer/` at commit
`3ea1134cf05d62c2b1db30362277a823d739ced2`.

For **JTFRAME cores**, also set the existing main OSD's `JTFRAME_OSDCOLOR`
macro to **`6'h35` (red)**. Update the core's existing definition, or include
`credits/jtframe_meat_osd.qip` from its `.qsf` after resolving conflicting
definitions. This is required even without optional artwork; details are in
`OSD_THEME.md`. Keep the credits renderer and real MiSTer/JTFRAME menu separate.

## 1. Compile the names

```powershell
python credits/tools/generate.py
```

The generated `.sv` and `.mif` initialize a shared true dual-port on-chip ROM.
The MIF is a Quartus build input included by the QIP; nothing is read from the
SD card at runtime. Only required glyphs are included. The generated include
contains dimensions, so growing the list needs no RTL parameter edits.

For automatic regeneration add this to your project `.qsf`:

```tcl
set_global_assignment -name PRE_FLOW_SCRIPT_FILE "quartus_sh:credits/preflow.tcl"
```

If the project already has a preflow hook, source `credits/preflow.tcl` from
that hook instead of replacing it. The stock template's `sys/build_id.tcl`
must still run to generate `build_id.v`. The demo's `preflow.tcl` chains both:

```tcl
source sys/build_id.tcl
source credits/preflow.tcl
```

Point `PRE_FLOW_SCRIPT_FILE` to that wrapper. The hook uses `python` on PATH; optionally
set the environment variable `CREDITS_PYTHON` to your Python executable.
`CREDITS_COLUMNS` changes the hook's default of 48 columns. Manual generation
must use the same `--columns` setting. A full compile is required after
changing names; an old RBF retains its old credits.

## 2. Add the sources

In the core's `files.qip`:

```tcl
set_global_assignment -name QIP_FILE credits/credits.qip
```

If this is an actual nested QIP, resolve that path relative to its own
`$::quartus(qip_path)`. The included QIP resolves its RTL and include paths
relative to itself. No edits to `sys/` are needed.

## 3. Add the menu action

In `emu`'s `CONF_STR`, before version/joystick lines:

```systemverilog
"R[120],Credits;",
```

`R` pulses the selected status bit and closes the OSD, as in MiSTer's Reset
and close OSD action. Pick an **unused** bit in the host core's status register
and use the same bit for the overlay instance. The sample uses `status[120]`
because the current template leaves it free. Older 64-bit cores must use a
free bit below 64 and the menu syntax supported by their platform version.
Reserve the bit in the host's status map; never reuse reset bit zero.

## 4. Insert into native video

Use the clock, pixel enable, RGB and blanking that belong to the **same native
video stage**. All video inputs and reset are synchronous to `clk_video`.
Blanking is active high; sync polarity is preserved. If RGB is 4 bits, expand
it first with `{component, component}`.

```systemverilog
wire [7:0] credits_r, credits_g, credits_b;
wire credits_hs, credits_vs, credits_hb, credits_vb, credits_de;
wire credits_active;
// Connect these raw hps_io outputs; include all controllers supported by the core.
// ps2_key[9] is the latest keyboard make/break state; mouse buttons are bits 2:0.
wire credits_dismiss = |(joystick_0 | joystick_1 | joystick_2 |
                         joystick_3 | joystick_4 | joystick_5) |
                       |buttons | ps2_key[9] | |ps2_mouse[2:0] | OSD_STATUS;

credits_overlay #(
    .WIDTH(320),       // Active width at THIS insertion point
    .HEIGHT(240),      // Active progressive height
    .SCALE_LOG2(0),
    .SCROLL_FRAMES(4)
) credits (
    .clk_video(clk_vid),
    .reset(video_reset),
    .ce_pixel(ce_pix),
    .menu_trigger(status[120]),
    .dismiss(credits_dismiss),  // Any key/button or reopening the main OSD closes credits
    .r_in(raw_r), .g_in(raw_g), .b_in(raw_b),
    .hs_in(raw_hs), .vs_in(raw_vs),
    .hblank_in(raw_hblank), .vblank_in(raw_vblank),
    .r_out(credits_r), .g_out(credits_g), .b_out(credits_b),
    .hs_out(credits_hs), .vs_out(credits_vs),
    .hblank_out(credits_hb), .vblank_out(credits_vb),
    .de_out(credits_de), .active(credits_active)
);
```

For a `video_mixer` host, feed **all seven** new signals to its inputs and use
`HALF_DEPTH=0`:

```systemverilog
.ce_pix(ce_pix),
.R(credits_r), .G(credits_g), .B(credits_b),
.HSync(credits_hs), .VSync(credits_vs),
.HBlank(credits_hb), .VBlank(credits_vb),
```

The mixer/scandoubler should follow the overlay. For a host directly driving
MiSTer's video outputs, assign `VGA_R/G/B`, `VGA_HS/VS`, and `VGA_DE` from the
credits outputs, and leave `CLK_VIDEO` and `CE_PIXEL` on the native clock and
pixel enable. The demo shows this direct-output case.

RGB and sync/blanking pass through the same three enabled register stages:
a pixel sampled at one enabled edge appears at the third enabled edge. All
outputs hold when `ce_pixel` is low. Use the **delayed blanking/sync**, including
when credits are closed, so RGB and timing stay aligned. Do not combine
credits RGB with the host's original timing.

## Clock domains and controls

`menu_trigger` and `dismiss` have two-register CDC synchronizers. The OSD
trigger pulse must last at least two video-clock cycles; normal `hps_io`
status pulses are much longer. Menu rising edges are accumulated and toggle
visibility at the next vertical blank. Even numbers of queued presses cancel.
Closing and reopening restores the opening layout, with the contributor thank-you centered and the title above it. A held trigger creates
one event. Connect `dismiss` to the raw controller, keyboard, mouse and MiSTer
menu signals as above, before any gameplay input masking. Declare/connect the
six 32-bit `joystick_0` through `joystick_5`, 11-bit `ps2_key`, 25-bit `ps2_mouse`
and 2-bit `buttons` outputs of `hps_io` if the host does not already use them.
Use only the ports available in an older host's `hps_io` version.

The opening button may remain held: dismissal arms after all inputs are released.
Then any button press closes credits at the next vertical blank. Short presses
are latched; they need not overlap vertical blank. Like the menu trigger, a
dismiss pulse must last at least two video-clock cycles for the CDC synchronizer.
Reopening the main MiSTer OSD also closes credits via `OSD_STATUS`.

Keep the host's existing HPS bus, OSD navigation and A/accept mapping intact.
`credits_dismiss` observes raw inputs; it must not consume, clear or gate them
before the real MiSTer menu sees them. Only the reserved Credits action bit
opens this overlay. A/accept on other menu entries retains its normal meaning.
The optional artwork must preserve the original inverted selection bitmap.

`active` belongs to `clk_video`. Synchronize it before using it in a different
clock domain. It can optionally pause gameplay; the credits themselves do
not change gameplay, audio or controller mapping. Keep raster generation live.

The credits move upward. Every name line has an eight-pixel blank row,
including wrapped names. Tier headings have continuous underlines. The footer
has at least eight blank rows before and after it; blank visual rows share
physical ROM data. Regenerate the complete generated directory after updating
this framework so its layout constants match the renderer.

## Geometry and compatibility

Default panel width is `(columns*6+16) << SCALE_LOG2`; this must fit `WIDTH`.
`HEIGHT` must be at least `64 << SCALE_LOG2`. Coordinates count active pixels
from the supplied H/V blanking rather than depending on sync polarity.

For variable native video modes, use a consistent progressive insertion
point, or provide a host-specific mode adapter. This first version has compile-time
geometry; it does not auto-detect changing resolution. An interlaced stream
must be made progressive before this renderer. Put the overlay before the
host's rotation if credits should rotate with the game. HDMI framebuffer cores
must render into a raster RGB stage; this module cannot alter an already-built
external framebuffer. An HDMI-only insertion will not also affect VGA.

The template demo is fixed to NTSC with native output to make its geometry
consistent. The untouched upstream checkout remains available for comparison.

For a native 320x240 core the default 48 columns make a 304-pixel-wide panel.
Names use two columns with a two-character gutter; the headers span both.
Each name gets 23 characters per line, with long names wrapping within its
column. For a native 256-pixel-wide core use `--columns 40`; each name then
gets 19 characters per line. Tier headings are Meat Kings (gold) and
Meatlovers (meat-red). `[gold]` and `[meat]` remain accepted as section aliases.

Reference: [MiSTer CONF_STR documentation](https://mister-devel.github.io/MkDocs_MiSTer/developer/conf_str/)
and [official template](https://github.com/MiSTer-devel/Template_MiSTer).
