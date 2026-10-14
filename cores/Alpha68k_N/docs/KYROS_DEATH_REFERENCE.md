# Kyros death and game-over reference

Source revision: 75fc12f01f3977d6289485f92d919c0d04d65dfd.

The derived recorder runs MAME 0.289's real Kyros CPUs with legal cabinet
inputs. It selects hard difficulty (IN1 = 206, default three lives), coins at
fields 120–125, starts at 160–165, then leaves movement and buttons neutral.
There are no game-memory or register patches. The canonical capture.lua is
unchanged. scripts/make_idle_death_capture.py records its guarded derivation
and source hashes in research/kyros_idle_death_source.json.

The corrected recording completed 7,200 fields, exit 0, without Lua errors.
All 7,200 IN1 observations equal 206; 38 screenshots were normalized from
official MAME PNGs into canonical inverse-ROT90 display RGB. Evidence and
exact command, executable/input hashes are in
research/kyros_idle_death7200_v2_exit.json. Captures are local ignored files
under sim/captures/kyros/idle_death7200_v2.

| Field | Visually observed state |
| --- | --- |
| 960 | Fighting, life indication 2 |
| 1200 | STAGE 1 CASTLE SKETCH transition, life indication 2 |
| 1680 | Fighting, life indication 1 |
| 2160 | Stage display, life indication 0 |
| 2400 | Fighting, no indicated reserve |
| 2640 | Player knocked down, body on ground |
| 2880, 3120 | CONTINUE / INSERT COIN / PUSH USER BUTTON |
| 3360 | PLAYER-1 GAME OVER |
| 3600 | Transition back toward title |
| 3840 | KYROS title |

These snapshots bound the sequence; they do not establish exact unsampled
death instants or interpret the reserve icons as a RAM life counter. Field
7199 is a later attract demonstration, not evidence of the first played
game-over.

The initial recording exited 3 because unqualified IN1 was absent in the
Lua port table. The derived script now accepts IN1 or :IN1. Its failure
receipt/capture are retained. The corrected run's initial validator searched
generic dips/dsw columns; the actual schema names the DIP column in1.
The receipt was corrected against all recorded rows, without rerunning MAME.

scripts/run_idle_death_native.py replays 3,601 fields through the actual
RTL CPUs and renderer with the recorded port file overriding canned inputs.
It snapshots the known current executable and binds ROM, input and RTL
manifest hashes. Its authoritative terminal will be
research/kyros_idle_death3601_exit.json; until that exists and is checked,
the native death/game-over sequence is pending.

Finite screenshots and field metrics alone do not establish broad
MAME_EXACT. Punch-hit/pickup coverage, HPS warm reset, paired live comparison,
Japan completion, Super Stingray MCU/gameplay, current feature runtime,
complete-design timing/resources and final authorized hardware remain open.
Software return to title does not establish a hardware reset pass.
Quartus remains disabled.
