# Sheriff controls and display audit

The active implementation is the Sheriff parent. Later family profiles must pass the same feature checklist independently. This audit does not close the gameplay, timing/resource or hardware release gates.

| Feature | Implementation and verified scope |
| --- | --- |
| Controls | Fire, Start 1, Start 2, Coin, Aim Right/Left/Up/Down, Pause. Existing two-player keyboard, dual-stick, rotary and pause qualification passes. MRA and OSD labels name these functions. |
| Service | Sheriff has no service-menu input in the [MAME 0.289 input definition](https://github.com/mamedev/mame/blob/mame0289/src/mame/nintendo/n8080.cpp#L778). EXP3 enables a diagnostic ROM outside the parent program; it is not a service menu. |
| DIP switches | Submenu named DIP switches: Lives (3/4/5/6), Cabinet (Upright/Cocktail), Unused SW1:3 through SW1:7. All eight physical positions reach IN3 / CPU I/O port 4 with the reference polarities. Unused switches have no assigned gameplay function. All 256 packed combinations pass actual CPU port reads. |
| Scaling | Normal, V-Integer, HV-Integer-, HV-Integer+, HV-Integer. The adapter follows the pinned platform video_freak helper, namespaces its modules and measures the rotated framebuffer dimensions. All 20 combinations of five modes, two orientations and 720p/1080p pass viewport and integer-multiple checks. |
| Rotation | HDMI 90-degree CCW/CW; native horizontal bypass. Rotate 180 changes source bitmap/PROM coordinates and composes with the game's cocktail flip on every output. Four flip combinations pass 458752 active pixels. Both DDR rotation mappings pass; extended CW stalls lose no writes. |
| High scores | Standard pinned JimmyStones module with Sheriff config at 0x60f1, three bytes. OSD open extracts changed scores and requests index-4 upload; autosave now defaults On. Startup guard, restore, request and uploaded bytes pass. Actual firmware filesystem persistence awaits hardware. |
| CRT adjustment | H-size and H/V position retain the existing native-sync adapter. Six neutral/size/position fixtures pass. Options appear only when applicable. Vertical size is not implemented or advertised. |
| Direct video | HPS direct_video is connected, framebuffer rotation is bypassed and HDMI-only choices are hidden. CRT resampling is disabled in this mode so the fixed native pixel cadence reaches the platform. Native 180-degree flip remains available. Adapter/display stability still needs hardware measurement. |
| Analog and Y/C | The unchanged pinned Template supplies native RGB/YPbPr, composite-sync and Y/C routing/encoding. MISTER_DISABLE_YC is not enabled in the QSF. Source support is present; electrical output and encoder/cable/display interoperability are not hardware-qualified. |

The integration was checked against the staged [Space Invaders core](https://github.com/MiSTer-devel/Arcade-SpaceInvaders_MiSTer/tree/db34f40586a572e30a2ada96fa683a7441a02866), the [Pac-Man HPS/direct-video pattern](https://github.com/MiSTer-devel/Arcade-Pacman_MiSTer/blob/master/Arcade-Pacman.sv) and the [pinned Template](https://github.com/MiSTer-devel/Template_MiSTer/tree/3ea1134cf05d62c2b1db30362277a823d739ced2). These are reference integrations, not a claim that one core is universally the most stable.

Native timing is 50.400 MHz / 10 = 5.040 MHz pixels, 320 pixels per line and 256 lines per field: **15.750 kHz horizontal and 61.5234375 Hz vertical**, 819200 master clocks per field. Flip tests verify the pixel and field periods. The PLL frequency is unchanged. HDMI scaler output timing remains the selected MiSTer output mode; the native refresh rate does not force every HDMI mode to that rate.

The HSync pulse at 272..303 and VSync at 248..251 remain the existing board-evidence assumptions. Nominal refresh correctness does not establish their exact original-PCB positions, widths, polarity or monitor tolerance. Full CRT/direct-video/Y/C/analog qualification therefore remains open.

Actual emu/HPS/board/sound/frontend/platform-model lint passes on Verilator 5.050. Verilator 5.032 requires a source-hashed simulation-only copy of screen_rotate that hoists three initialized static counters; production sys is unchanged. The native flip/DIP unit fixture isolates unrelated sound outputs while retaining the real board renderer and 8080.

Recover results through docs/evidence/sheriff_display_features.json and its ignored log paths/hashes. Quartus remains on hold, current-source fit/STA/resource qualification is deferred, GENERATE_RBF_FILE remains OFF, and no RBF was assembled.
