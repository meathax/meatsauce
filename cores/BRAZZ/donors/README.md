# Staged donor sources

`manifest.json` pins nine public source/reference snapshots. The directories remain local and Git-ignored; commits retain this manifest, provenance index and the reproducible staging script instead of large duplicate upstream checkouts. Each local snapshot includes its own `PROVENANCE.json/.md` and `FILES.json`.

Use `../docs/DONOR_MAP.md` for suitability and limitations. `jtframe` contains the selected `modules/jtframe` subtree from JTcores; `siliconre` contains selected K054539 documentation. Other snapshots contain upstream source excluding binary releases/ROM fixtures. Nested submodules are not recursively fetched.

No compatible public SE3208 or complete VRender0 RTL was located. These references do not eliminate custom target CPU/video/sound/SoC work. License metadata is not permission to mix incompatible or unlicensed source; inspect selected file notices before copying into `rtl/vendor/`.

Recover missing directories with `python -X utf8 scripts/prepare_sources.py` from the project root. Existing manifest revisions are preferred; do not silently upgrade dependencies. Source fetches require network access. Local ROM/MAME paths are configured in that script and the ignored `mister.env`; commercial ROM archives are never downloaded from the internet by it.
