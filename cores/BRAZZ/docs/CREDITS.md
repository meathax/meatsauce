# MeatCore Credits integration

The portable framework is copied unchanged from `CREDITS/credits`. The names in
the project-root `credits.txt` come from the 2026-10-06 Patreon member export:
the Meat Kings tier is listed under Meat Kings and every other active member
under Meatlovers (32 names). The optional main-OSD artwork is not installed,
because it patches `sys/osd.v` and this project keeps `sys/` pristine; the stock
MiSTer OSD, its row highlight and its selection handling are unchanged.

| Binding | CrystalSystem integration |
| --- | --- |
| Project / revision | `CrystalSystem.qpf` / `CrystalSystem` (Quartus 17) |
| Menu / status | `"R[120],Credits;"` after `DIP;`, before the reset rows; bit 120 of the 128-bit status is used only by the overlay. The row has no `H`/`D` prefix, so it is visible in every `status_menumask` state and OK on the highlighted row pulses bit 120 and closes the OSD |
| Native video | `cs_video_hold` output: progressive 320x240, 24-bit RGB, active-high blanking, live while the game is reset or loading |
| Clock / reset / CE | `clk_sys`, power-on `memory_reset`, `native_ce` |
| Output routing | Overlay RGB, sync and blanking feed `arcade_video`; the HDMI rotation framebuffer takes the same RGB/DE with raster X/Y delayed by the overlay's three enabled stages, so credits rotate with the game |
| Panel | 48 columns, scale 0, 304 pixels wide; one pixel upward every four frames |
| Dismissal | Raw `joystick_0`..`joystick_5`, PS/2 make bit 9, mouse buttons 2:0, both HPS buttons and `OSD_STATUS` |
| Sources / hook | `files.qip` includes `credits/credits.qip`; `credits_preflow.tcl` chains `sys/build_id.tcl` and `credits/preflow.tcl` |

Credits never pause the game; gameplay inputs stay live.

Edit the UTF-8 `credits.txt` and regenerate from the project root:

```powershell
python credits/tools/generate.py --columns 48
python scripts/verify_credits.py
```

`verify_credits.py` checks the host bindings (including the visible menu row
order for every menumask state), runs the framework regression on the actual
host instance and dismiss expression (CE alignment, centered opening, upward
scroll, wrap, held opener, short taps, reset, all 192 controller bits and 256
keyboard codes), checks both tier colours in native captures and runs the
chained preflow with Quartus queries stubbed. Changing names requires a new RBF.
