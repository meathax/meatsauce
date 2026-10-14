# Sheriff gameplay coverage

The saved cb67879 main-board replay completed6,781 fields with actual exit0. Current board source differs only by the user-flip input and its two scanout coordinate XORs. With that input off, exact source specialization restores the captured board; CPU kernel/wrapper hashes also match. This reuses main-program evidence without qualifying changed audio or the current complete MiSTer wrapper.

| Requirement | Evidence and scope | Remaining work |
|---|---|---|
| Attract and coin/start | Native field600 INSERT COIN; field780 GET READY after ordinary coin600/start690. | Current whole-wrapper late lifecycle. |
| P1 score changes | ROM-rendered scores0000,0030,0060,0090,0210; control RAM matches MAME. | Other round progression and all required effects. |
| Deaths and game over | Native lives3 at1200/1800,2 at2400/2760/3900,1 at4800,0 at6060; stable GAME OVER at6060/6120 with score0330. | Full current-wrapper and both-player terminal sequence. |
| Restart and highscore retention | Coin6200/start6290; field6780 has3 lives, score0030 and retained HI-SCORE0330. | Highscore persistence feature has separate save/restore qualification. |
| Movement and independent aiming | Prior current-gameplay/centered-wrapper evidence records real input reads and P1 gameplay; see its source scope. | Combine remaining integration milestones on the final source. |
| P2/cocktail | Prior sheriff_current_cocktail.json covers4801 fields,85 RGB exports and the first P2 turn; retained callback-ordering limits apply. | Complete current-wrapper two-player lifecycle. |
| Cleared rounds/red effect | Ordinary-input MAME rounds reference has no memory/ROM patches; first red control14 at11302. | Corrected/final RTL round-effect campaign after resolving the first divergence. |

At117 shared snapshots, native/MAME control RAM6000..603f is exactly equal;53 whole-RAM snapshots are equal. Every other whole-RAM difference is retained by address in `docs/evidence/sheriff_gameplay_lifecycle.json`. No tolerance or state/reference offset was applied. These RAM facts and readable HUD observations do not waive graphics or IRQ/DRAM timing failures.

The field6000 image contains a partially drawn GAME O; use6060/6120 for the stable game-over observation. Upright inspection applies only a lossless90-degree counterclockwise image rotation. Original PPM/RAM/state files are unchanged, hashed and locally recoverable.

Recovery: `docs/evidence/sheriff_gameplay_source_bridge.json`, `sheriff_gameplay_lifecycle.json`, ignored `_checks/gameplay-source-bridge-20261010/`, and `sim/results/physical-cpu-restart-corners-rtl-20261009/`. No new simulation/build was needed for this unchanged main logic. Complete gameplay, strict graphics, whole-audio, timing/resources and release remain open.
