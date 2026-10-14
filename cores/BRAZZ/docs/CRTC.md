# VRender0 CRTC

`rtl/video/vr0_crtc.sv` contains the synthesizable register block, system-clock pixel divider, beam counters, active area, blanking, frame counter, and IRQ24 / GPU flip events. The probe routes `0x01803400–0x018037ff` to it and removes the former fixed vblank counter. MAME selects alternate vblank/flip events in interlace mode; this behavior is implemented. Screen blanking comes from CRTMOD bit 9.

The independent test oracle retains five full function bodies unchanged from the pinned [MAME 0.289 VRender0 controller](https://github.com/mamedev/mame/blob/mame0289/src/devices/machine/vrender0.cpp). Its screen adapter records the geometry and supplies the DUT beam position for register reads; it does not advance the RTL raster. Register masks, write protection, reserved reads, enable-gated total writes, auto-total updates and inclusive MAME status boundaries are compared directly.

The private native game capture contains 36 CRTC writes. The initial 640-pixel interlace setup is followed by the game's 320-pixel progressive setup. Final values include HDISP=319, VDISP=240, HTOT=`0x5c6`, VTOT=`0x9f9`, STAD1=`0x4001`, and CRTTIM=`0x8b`. Under MAME's documented timing interpretation these select a **455×262 raster**, **320×240 visible pixels**, and **7.15909 MHz pixel clock**. Each frame takes **1,430,520 system clocks** at 85.90908 MHz.

`python -X utf8 scripts/sim.py crtc` exits **0** with **4,560,921 checks / 6,078,720 clocks**. It replays all 36 setup writes, checks register masks/protection/reserved addresses, measures three complete real-rate frames and active pixel counts, exercises all 16 internal divider/speed combinations, external tick selection, blanking, and interlace event selection. Evidence: `docs/simulation_crtc.json`, `docs/crtc_reference.json`.

The integrated production-default CPU probe builds with this controller and reaches the same unresolved cartridge `MVTC` at PC `0x020820c4` after 8,233,974 compared instructions / 154,545,349 clocks. Its exit status remains **1**. No boot completion, rendered game frame or attract/gameplay acceptance is claimed.

## Remaining physical and integration work

- MAME explicitly guesses several total/porch rules, the nine-line adjustment and some clock semantics. Passing this oracle establishes reference compatibility, not physical timing proof.
- HS/VS output placement is provisional. In particular, the current vertical waveform uses FWINB's lower field bits as a sync-window width; this is an implementation assumption requiring a hardware manual or captured signals. Half-line interlace is not implemented. Do not use these pins as acceptance evidence until resolved.
- The external clock port supplies **final pixel ticks**. The Crystal System probe ties it low because no external video source is configured. A future board wrapper must provide the selected external source if required.
- Geometry changes restart the beam/divider immediately. Mid-frame physical reconfiguration timing is unverified. The game setup replay exercises register ordering, not live raster reconfiguration accuracy.
- Framebuffer scanout, CRT display-start addressing, border/superimpose behavior, final output polarity, MiSTer video integration and realistic shared-memory bandwidth remain pending. GPU packet rendering is a separately tested component.
