"""Vendor pinned CPUs and record the minimal, shared simulator/synthesis adaptation."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CHOICES = {
    'fx68k': ('fx68k', '0602ee4627b10f301298f2673d826cdd6baa9327',
              ['fx68k.sv', 'fx68kAlu.sv', 'uaddrPla.sv', 'microrom.mem', 'nanorom.mem']),
    't80': ('jtcores', '548b87b32a1b528a16cb41f689accb179e85d1a8',
            ['modules/jtframe/hdl/cpu/t80/T80s.v']),
}


def main():
    records = []
    for label, (repository, revision, paths) in CHOICES.items():
        donor = ROOT/'donors'/repository
        actual = subprocess.check_output(['git', '-C', str(donor), 'rev-parse', 'HEAD'], text=True).strip()
        assert actual == revision, f'Donor revision changed: {repository}'
        target = ROOT/'rtl/vendor'/label
        target.mkdir(parents=True, exist_ok=True)
        paths += [p.name for p in donor.iterdir() if p.is_file() and p.name.lower().startswith(('license', 'copying'))]
        for name in paths:
            source = donor/name
            dest = target/source.name
            original = source.read_bytes()
            data = original
            adaptation = None
            if label == 'fx68k' and name == 'fx68k.sv':
                data, count = re.subn(rb'typedef struct\s*\{', b'typedef struct packed {', original)
                assert count == 3, 'Unexpected fx68k signal-struct declarations'
                adaptation = 'Pack three signal-only structs for non-overlapping member drivers in Verilator 5.050; no logic/microcode change'
            if dest.exists():
                assert dest.read_bytes() == data, f'Vendored file changed: {dest}'
            else:
                dest.write_bytes(data)
            records.append({'path': dest.relative_to(ROOT).as_posix(), 'source_path': name,
                            'donor': repository, 'revision': revision,
                            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                            'source_sha256': hashlib.sha256(original).hexdigest(), 'adaptation': adaptation})
    (ROOT/'rtl/vendor/provenance.json').write_text(json.dumps(records, indent=2)+'\n', encoding='utf-8', newline='\n')
    (ROOT/'rtl/vendor/PROVENANCE.md').write_text(
        '# CPU provenance\n\nSources come from the revisions in `provenance.json`.\n'
        'fx68k: https://github.com/ijor/fx68k . T80 generated Verilog: '
        'https://github.com/jotego/jtcores/tree/548b87b32a1b528a16cb41f689accb179e85d1a8/modules/jtframe/hdl/cpu/t80 .\n'
        'Retain source license headers and the copied repository license files. '
        'T80s contains its generated dependency closure in one file; its VHDL-origin notices are retained.\n'
        'fx68k.sv has only three signal structs changed to packed. Independent continuous/NBA member '
        'drivers otherwise trigger BLKANDNBLK in Verilator 5.050. Logic and microcode are unchanged. '
        'The adapted source is shared by simulation and synthesis; original/imported hashes are retained.\n',
        encoding='utf-8', newline='\n')
    print('Vendored', len(records), 'CPU source/memory/license files with recorded provenance.')


if __name__ == '__main__':
    main()
