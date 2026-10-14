# Source attribution and license handling

The project scaffold comes from
[MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer).
Its untouched source and `sys/` retain their original notices; the original
template license is preserved under `reference/template/LICENSE`.

The intended project license is GPL-3.0-or-later, matching the selected
Seibu donor and Jotego modules. The root license text is copied from the
pinned rmonic79 Raiden II donor. Individual third-party files keep their own
notices and compatible original licenses; the project license does not
relicense those files.

Exact repository URLs, commits, submodule commits and discovered license
files are in `donors/manifest.json`; each donor checkout also carries
`STAGING_PROVENANCE.json`. These checkouts are source staging, not active
project dependencies. When copying a module into active RTL, create a
`PROVENANCE.md` beside it with upstream commit, exact source paths, original
license and local changes.

Key authors: Umberto Parisi (Seibu donor integration / CRT Adjust), Martin
Donlon (NEC `ucore` / Irem source and test references), Jose Tejada
(JTOPL, JT6295 and JTFRAME), Daniel Wallner / MikeJ and contributors (T80),
Sorgelig / MiSTer-devel (platform), and the authors named in MAME file headers.

MAME reference source preserves its LGPL/BSD or other original per-file
notices. The local full MAME executable is used for reference extraction;
it is not copied into or distributed with this repository.

No repository-wide license was found during staging for some exploratory
donors, including SeibuSPI. Treat such source as reference-only unless the
specific files have a clear compatible license. Do not infer permission
from repository visibility. T80's license is supplied in its HDL headers.
The exact V30 copy already integrated into the licensed Raiden II donor is
the implementation default; upstream NEC tests are supporting evidence.

Game ROMs, PCB credentials and device passwords are never committed.

The active target sound wrapper also derives from the pinned Raiden donor;
JTOPL2 retains Jose Tejada's GPL notices and TV80 retains Guy Hutchison's
permissive notices. See `rtl/ZeroTeam_audio.PROVENANCE.md`,
`rtl/sound/PROVENANCE.md` and `rtl/tv80/PROVENANCE.md` for local changes.
