"""Report writes outside the proposed shared-enable TV80 scope."""
import json
import re
from pathlib import Path

s = Path('rtl/tv80/tv80_core.v').read_text()
s = re.sub(r'/\*.*?\*/', lambda m: '\n' * m[0].count('\n'), s, flags=re.S)
s = re.sub(r'//[^\n]*', '', s)
ranges = []
for m in re.finditer(r"if\s*\(\s*(?:ClkEn|cen)\s*==\s*1'b1\s*\)\s*begin\b", s):
    level = 1
    for t in re.finditer(r'\bbegin\b|\bend\b', s[m.end():]):
        level += 1 if t[0] == 'begin' else -1
        if not level:
            ranges.append((m.end(), m.end() + t.end()))
            break
sdc = Path('ZeroTeam.sdc').read_text()
names = set(re.search(r'set zt_z80_ce_names\s*\{([^}]+)\}', sdc)[1].split())
reset_ranges = []
for m in re.finditer(r"if\s*\(\s*(?:reset_n\s*==\s*1'b0|~reset_n)\s*\)\s*begin\b", s):
    level = 1
    for t in re.finditer(r'\bbegin\b|\bend\b', s[m.end():]):
        level += 1 if t[0] == 'begin' else -1
        if not level:
            reset_ranges.append((m.end(), m.end() + t.end()))
            break
outside = []
for m in re.finditer(r'\b(\w+)\s*(?:\[[^\n;]*?\])?\s*<=\s*([^;]+);', s):
    if m[1] in names and not any(a <= m.start() < b for a, b in ranges):
        assert any(a <= m.start() < b for a, b in reset_ranges), f'Normal write outside CE: {m[1]}'
        outside.append(dict(line=s[:m.start()].count('\n') + 1, register=m[1], rhs=m[2].strip()))
assert not re.search(r'always\s*@\s*\([^)]*negedge\s+clk\b', s)
assert len(names) == 50 and len(ranges) == 6
print(json.dumps(dict(scoped=len(names), branches=len(ranges), reset_writes=len(outside),
                     normal_writes_outside_ce=0, no_falling_clock_processes=True)))
