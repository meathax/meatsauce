# Main MiSTer OSD theme

This document covers the required red setting for JTFRAME integrations and
the optional artwork behind the **main MiSTer platform OSD menu**.
The scrolling credits are a separate renderer. The menu artwork does not enter
the credits pixel pipeline or cover the game screen outside the menu rectangle.

## JTFRAME cores: required red menu color

For every JTFRAME core receiving this framework, set the existing main OSD's
six-bit background macro to **`JTFRAME_OSDCOLOR=6'h35`**. The requested value is
listed as red in the [JTFRAME OSD documentation](https://github.com/somhi/jtframe/blob/master/doc/osd.md).
This requirement also applies when installing just credits, without the artwork.

Prefer updating the core's existing `JTFRAME_OSDCOLOR` definition in its own
configuration/macros file. Follow the numeric syntax accepted by that host's
generator: the value is hexadecimal `35`, decimal `53`, or Verilog `6'h35`.
Verify that its effective MiSTer Verilog macro has that value. Keep one
authoritative definition and resolve conflicting defaults or later overrides.

For a host using Quartus macro assignments, this ready-to-use fragment is
included in the framework. Add it once to the project `.qsf`:

```tcl
set_global_assignment -name QIP_FILE credits/jtframe_meat_osd.qip
```

The fragment contains the exact assignment:

```tcl
set_global_assignment -name VERILOG_MACRO "JTFRAME_OSDCOLOR=6'h35"
```

Use the existing definition or the fragment after removing conflicting values.
Apply the setting at core scope, so other cores sharing JTFRAME keep their own
configuration. The macro belongs to JTFRAME's existing OSD and needs no new
menu renderer, artwork ROM or credits palette change. The stock MiSTer template
uses a different, three-bit `OSD_COLOR` parameter; retain that interface when
working on a stock-template host.

The generic `credits/credits.qip` intentionally leaves this JTFRAME-only fragment
separate. Detect the host platform and apply it for every JTFRAME integration.
No RBF build is implicit in this configuration change; an RBF build/rebuild
still requires an explicit user request.

## Optional meat artwork

The artwork is a fully opaque deep meat-red background with subtle marbling
and a large centred **MEATCORES** watermark. Standard OSD text and selection
bits render on top in warm white. The four background shades range from
`#230A11` to `#4C1723`, keeping the foreground readable.

The real MiSTer menu keeps ownership of navigation and A/accept. Selected rows
use the original inverted bitmap: a bright selection bar with dark text.
The artwork changes only the background RGB; never redraw menu text or its
selection, intercept controller buttons, or replace the HPS command interface.
The stock/themed OSD regression compares control state and video timing on every
clock, then checks identical text and selection masks before and after moving
the highlight, in all four supported size/rotation modes.

![Compiled menu background, native ROM pixels](credits/osd/assets/meatcores_128x64.png)

## Dimensions and footprint

MiSTer's normal expanded menu is **256x128 logical pixels**, a **2:1** canvas.
The stored artwork is **128x64**, **2 bits per pixel**, and doubles in both axes
inside that rectangle. It consumes **16,384 ROM bits per OSD instance**; stock
MiSTer normally instantiates separate HDMI and VGA OSDs. At this depth and
width, each instance uses two M10K blocks. No runtime PNG or memory file is used.

The watermark is inset to the right of the **20-pixel logical sidebar**.
Its full word fits within approximately **11%–95% of the canvas width**, so
the sidebar leaves the M visible and the S retains a right margin.

The compact 256x64 menu uses the **central 64 rows of the 256x128 image**.
This is a crop, preserving the watermark's proportions. Portrait OSD rotation
uses the same logical coordinate mapping as the foreground bitmap, and the
OSD's existing multiscan/pixel scaling scales artwork and text together.
Info/toast boxes retain the stock compositor, without the branded artwork.

## Install into a core

After copying `credits/` and adding `credits/credits.qip` as described in
`INTEGRATION.md`, run from the host core's root:

```powershell
python credits/tools/install_osd_theme.py --core .
```

This updates **one file**, `sys/osd.v`, only at its RGB compositor and at the
matching bitmap-coordinate capture. It creates a byte-exact backup named
`sys/osd.v.meatcores-original`. It does not change the upstream checkout in
this project. Running the installer again is harmless. Unsupported custom
OSD implementations cause a clear error before any source is changed.

Restore by copying that backup over `sys/osd.v`. Keep the backup for comparison
when updating the MiSTer platform; reapply or port the theme after such updates.
Credits themselves need no `sys/` changes; this separate branding feature does.

Custom JTFRAME OSDs need the same compositor integration ported into their
`osd.sv`: replace the existing logo/background output, retain the bitmap text
and OSD window mux, and feed the artwork ROM with the menu's logical coordinates.
The installer deliberately targets the stock MiSTer implementation used by
the included official template; it does not overwrite JTFRAME's existing logo.

## Regenerate artwork

The original built-in ImageGen artwork and prompt are kept in `docs/artwork/`
in the full project. The portable ZIP includes the native bitmap and prompt.
To compile a replacement **2:1** bitmap (Python with Pillow, at build time):

```powershell
python credits/tools/compile_art.py path/to/your_2_to_1_artwork.png
```

The script validates the source aspect ratio, downsamples to native ROM
dimensions, quantizes to four dark red shades, and writes the embedded ROM and
native PNG preview. Name edits do not require recompiling artwork; the normal
credits preflow hook only regenerates the names/font ROMs.

Design reference: Jotego uses a custom OSD colour and a logo/background ROM in
the platform OSD compositor. This framework follows that insertion point with
its own MIT-licensed glue and original generated artwork; no Jotego logo or
logo ROM was copied. Reference source: [JTFRAME osd.sv](https://github.com/jotego/jtcores/blob/master/modules/jtframe/target/mister/hdl/sys/osd.sv).
