# Releases

Status: the RBF below is timing-closed but is **not hardware-validated and not game-validated** (cold boot, attract, gameplay, sound and persistence are unproven; see `progress.md`). Nothing in this folder claims MiSTer hardware operation.

## Contents

| File | Purpose |
|---|---|
| `Arcade-CrystalSystem_20261007.rbf` | Core bitstream (git-ignored). Built from the commit / fit snapshot recorded in `progress.md` (entry "2026-10-07 final audit and release RBF"; commit f36ed6d, fit snapshot `1791375258576220400`, sha256 `f44a94f70b483e9f96aecbadada09a6ab25236dfd1bcbeb8abac254e558fc408`; TIMING.md). The RBF is built separately; this folder's MRAs only name the undated prefix `CrystalSystem`. |
| `The Crystal of Kings.mra` | Primary MRA, default AMG0110B BIOS (`mx27l1000.u14`). |
| `_alternatives/_The Crystal of Kings/The Crystal of Kings (AMG0110D BIOS).mra` | Alternate MRA using the AMG0110D BIOS (`mx27l1000-alt.u14`). Same setname/game data; only the first 128 KiB differ. |

Regenerate and verify with `python scripts/build_mra.py --check`, then `python scripts/validate_mra.py "releases/*.mra" "releases/_alternatives/*/*.mra"`.

## ROMs (user supplied, never committed)

Place `crysking.zip` and `crysbios.zip` from MAME 0.289 in `/media/fat/games/mame/`. Required members:

| Zip | Member | Size | CRC32 |
|---|---|---:|---|
| crysbios.zip | mx27l1000.u14 (AMG0110B, default) | 131072 | beff39a9 |
| crysbios.zip | mx27l1000-alt.u14 (AMG0110D, alternate MRA only) | 131072 | 1e8175c8 |
| crysking.zip | bcsv0004f01.u1 | 16777216 | 8feff120 |
| crysking.zip | bcsv0004f02.u2 | 16777216 | 0e799845 |
| crysking.zip | bcsv0004f03.u3 | 16777216 | 659e2d17 |

## Index 0 stream

50,462,720 bytes: 128 KiB BIOS, then the three 16 MiB flash images back to back (48 MiB). The MRA applies MAME's eight `init_crysking` little-endian halfword replacements (cartridge offsets 0x7bb6, 0x7bb8, 0x8096, 0x8098, 0x8a52, 0x8a54, 0x976a, 0x976c) as literal parts; the archives are not modified. `<nvram index="4" size="65536"/>` carries the 64 KiB board SRAM.

## Controls (identical in CONF_STR and the MRA)

Buttons: Attack, Jump, Magic, `-` (unused 4th action slot), Start, Coin, Pause, Service Credit, Service Menu. Default mapping `A,B,X,-,Start,Select,L,-,-`. Two players are wired.

DIP switches (eight positions, default FF = all Off): Pause (bit 0), Free Play (1), Unknown DSW 3 to Unknown DSW 7 (bits 2-6), Test (7). Pause, Free Play and Test match MAME; DSW3-7 are unnamed in MAME.
