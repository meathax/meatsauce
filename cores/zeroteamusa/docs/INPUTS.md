# Zero Team USA input contract

Source: MAME 0.289 `raiden2.cpp:767–959` and
`src/mame/shared/seibusound.h:167–176`.

All player, start, service and coin switches are active-low. Idle player and
coin bytes are `ff`; idle DSW and SYSTEM words are `ffff` in the default 2P
cabinet. Sound reads the raw coin byte at `4013`; the main V30 reads P1/P2
at `744`, P3/P4 at `748` and SYSTEM at `74c`.

| Player byte bit | Meaning |
| --- | --- |
| 0, 1, 2, 3 | Up, Down, Left, Right |
| 4, 5 | Attack, Jump |
| 6 | MAME declares a third raw switch; unused by the two-button cabinet |
| 7 | Unused, held high |

Coin 1/2/3/4 use bits 0/1/2/3 of the sound coin byte; all other bits remain
high. Use four native video frames for the reference coin impulse.
Start 1/2/3/4 use SYSTEM bits 0/1/**4/5**. SYSTEM bit 3 is service credit.
The SYSTEM service-mode switch is bit 11, separate from the DSW word.

| Cabinet | SYSTEM mask `0700` value | Complete idle SYSTEM word |
| --- | --- | --- |
| 2P | `0700` | `ffff` |
| 3P, 3 slots | `0600` | `feff` |
| 4P, 4 slots | `0500` | `fdff` |
| 3P, 2 slots | `0400` | `fcff` |
| 2P × 2 | `0300` | `fbff` |
| 4P, 2 slots | `0200` | `faff` |
| 2P freeplay | `0100` | `f9ff` |
| 4P freeplay | `0000` | `f8ff` |

Select the cabinet before cold boot for cabinet validation. The input CSV
contains raw port values and affects only these physical inputs. It never
changes game RAM, ROM, CPU registers, protection state or credits directly.

The earlier sound/activity runs drove coin idle as zero, incorrectly holding
coin inputs active. They remain historical electrical/video evidence, not
proof of correct uncredited attract or credited gameplay. The corrected
harness uses idle `ff` and clears the selected bit for a coin impulse.

## Staged MiSTer frontend

The wrapper accepts four pads with Attack and Jump, matching the two-button
cabinet. The special move is performed by pressing Attack and Jump together,
as on the original game; the spare physical bit 6 stays high. Every pad has
its own start and coin, and can request pause. Service credit and service-mode
switch are available as remappable Service/Test actions. The second loaded
DIP word supplies SYSTEM cabinet bits 10:8 and service-mode bit 11; the final
MRA must use this layout. These frontend component checks do not prove live
four-player gameplay or final MiSTer integration.

| Player | Directions | Attack / Jump | Start | Coin |
| --- | --- | --- | --- | --- |
| 1 | Arrow keys | Left Ctrl / Left Alt | 1 | 5 |
| 2 | I / K / J / L | Z / X | 2 | 6 |
| 3 | T / G / F / H | B / N | 3 | 7 |
| 4 | Keypad 8 / 5 / 4 / 6 | Keypad 1 / 2 | 4 | 8 |

Keyboard P requests pause; F2 supplies a service credit; F3 holds the
service-mode switch active. Extended arrow keys and nonextended keypad keys
are decoded separately. User savestates are disabled because target audio
state capture/restoration is not implemented; native simulation checkpoints
are a separate diagnostic facility. See `PLATFORM_OPTIONS.md` for the target
loader/video wiring and the source/simulation acceptance evidence. Analog-stick
mapping and live four-player gameplay remain separate acceptance gates.
