# Current wrapper input stimulus

The first current wrapper hostile-seed1 replay terminates with actual exit0
and 1201 captured fields. It shows GET READY and the game arena, and the real
CPU reads coin, Start1 and Fire1. It does **not** reproduce every frozen P1
movement/aim value. Its original boot/configuration and outputs remain in
`.preflight/runs/20261010-043322/` and
`_checks/current-wrapper-gameplay-1201-20261010/run-v3/`.

The boot writes digital joystick0/1 but never writes analog channels. The
template's four analog output registers have no declared initialization or
reset in `sys/hps_io.sv`. The board combines digital and analog directions,
rejecting contradictory directions, so hostile retained analog values alter
the intended digital-only stimulus.

`tools/qualify_wrapper_input_boot.py` reuses the exact compiled wrapper objects
and matching runtime. A private host observer reads the actual HPS output
registers; it never assigns game/model state. Both 30ms cases exit0 and receive
all14 intended digital-word pairs. The untouched case retains P1 analog
values `0xf91e` (left) and `0xfa8c` (right). The latter is signed X=-116/Y=-6:
Left aim. It explains the real CPU's initial IN0=32 with joystick0=0 and
IN0=1 when Right movement/Right aim/fire arrive as joystick0=273. Opposing
Left/Right aim is cancelled by the already qualified controls RTL.

The centered case sends the real HPS commands `0x1a` (left analog) and `0x3d`
(right analog), each with player index0/1 and packed X/Y=0. All matching
observations then have all four analog channels zero; Rotate and Pause remain
zero. Local terminal receipt:
`_checks/wrapper-analog-boot-20261010-v3/terminal.json`.
The firmware uses these command/packed-axis contracts in
[Main_MiSTer user_io.cpp](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.cpp).
This establishes a fixture omission; it does not claim that every real firmware
boot sends this exact sequence or qualify disconnected-device behavior.

The first probe preparation failed to route cc1plus. The second compiled
successfully but passed obsolete positional runtime arguments; it failed to
load a boot script before model execution. Both preparations remain retained.
The third uses the builder's compiler-routing environment and the harness's
actual `+pf_dir=`, random-reset and seed arguments. It reuses the successful
private executable after checking source/object identity, avoiding another RTL
or observer build. Runtime receipts retain actual return codes.

Future gameplay stimuli explicitly center all four analog channels via HPS
before `boot_done`. Preserve the original negative; do not force registers,
mask analog support, alter the core to accommodate this fixture, or use the
short input probe as proof of full gameplay/MAME graphics equivalence.

Preflight's source/settings cache does not include this process-local boot
adapter. `--rebuild` alone returned the original cached report for the first
centered request, without compiling an observer or executing a native run.
That terminal CLI exit0 is retained in
`_checks/current-wrapper-neutral-1201-20261010/` and is not scenario evidence.
The producer now requests `--force` and requires `native-result.json` before
accepting a terminal result. The fresh centered replay reuses unchanged RTL
objects at source fingerprint `a220ba2c8c553374`; recovery is
`_checks/current-wrapper-neutral-1201-20261010-force/launch.json` and
`.preflight/runs/20261010-054834/`. Its completion and exact input reads are
pending. No Quartus, assembly or new hardware source change accompanied these
fixture corrections.

The centered full-wrapper replay has now completed1201 fields with actual worker/native exit0 and unchanged sourcea220ba2c8c553374. All14 scheduled P1 movement/aim values, coin/start/fire are observed. `docs/evidence/sheriff_current_wrapper_centered_gameplay.json` binds the ordinary HPS boot commands and actual native result. This qualifies the finite input replay; complete lifecycle, wrapper/MAME moving-picture phase, mixed audio and timing/resource gates remain separate. Preserve the earlier uncentered negative and cached nonexecution.
