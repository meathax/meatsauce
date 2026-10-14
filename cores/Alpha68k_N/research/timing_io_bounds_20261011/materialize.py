import hashlib
import json
from pathlib import Path

ROOT = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
STAGE = Path(__file__).resolve().parent
FIT = Path(r'D:\Arcade\AI\aCORES\Alpha68k N\research\sound_write_width\case2_full_map')
REPORT = FIT / 'output_files/Alpha68k_N.sta.rpt'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(name, data):
    (STAGE / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8', newline='\n')

def main():
    expected_report = '239157e426e901fd3a4d5db12ddb62fa9c83695bd3056539e66d76758dedc664'
    assert sha(REPORT) == expected_report
    rows = REPORT.read_text(encoding='utf-8', errors='strict').splitlines()
    def table(first, last):
        out = []
        for line in rows[first - 1:last]:
            cols = [v.strip() for v in line.split(';')]
            if len(cols) >= 4 and ('No input delay' in cols[2] or 'No output delay' in cols[2] or cols[2] == 'Partially constrained'):
                out.append({'port': cols[1], 'comment': cols[2]})
        return out
    inputs, outputs = table(1439, 1463), table(1467, 1556)
    assert len(inputs) == 20 and len(outputs) == 85
    assert len({x['port'] for x in inputs}) == 20 and len({x['port'] for x in outputs}) == 85
    pins = []
    evidence_ranges = {
        'Alpha68k_N.sdc': [(1,5)],
        'Alpha68k_N.sv': [(52,74),(177,209),(267,300)],
        'sys/sys_top.sdc': [(1,39)],
        'sys/sys_top.v': [(128,175),(232,285),(1129,1139),(1262,1297),(1304,1337),(1549,1577),(1608,1629),(1659,1675),(1857,1876)],
        'sys/mcp23009.sv': [(20,41)],
        'sys/i2c.v': [(22,41),(59,99)],
        'sys/i2s.v': [(19,51)],
        'sys/audio_out.sv': [],
        'rtl/alpha68kn_pll.sv': [(1,20)],
        'rtl/alpha68kn_gfxmem.sv': [(72,95)],
        'rtl/vendor/jtframe_sdram/jtframe_sdram64.v': [(175,221)],
        'research/quartus_sdram_constraint_spec.md': [(1,18)],
        'research/quartus_sdram_constraint_spec.json': [],
        'Alpha68k_N.qsf': [],
    }
    excerpts = {}
    for rel, ranges in evidence_ranges.items():
        path = ROOT / rel
        raw = path.read_bytes()
        pin = {'relative_path': rel, 'path': str(path), 'sha256': sha(path), 'bytes': len(raw)}
        frozen = FIT / 'source' / rel
        if frozen.exists():
            pin['fitted_source_path'] = str(frozen)
            pin['fitted_source_sha256'] = sha(frozen)
            pin['canonical_matches_fitted_bytes'] = raw == frozen.read_bytes()
        pins.append(pin)
        lines = raw.decode('utf-8').splitlines()
        excerpts[rel] = [
            {'start_line': a, 'end_line': min(b,len(lines)), 'lines': [{'line': n, 'text': lines[n-1]} for n in range(a,min(b,len(lines))+1)]}
            for a,b in ranges
        ]
    groups = {
        'SDRAM electrical': {'inputs':16, 'outputs':35},
        'HDMI video': {'inputs':0, 'outputs':28},
        'HDMI audio': {'inputs':0, 'outputs':4},
        'HDMI HPS I2C': {'inputs':1, 'outputs':2},
        'HDMI interrupt': {'inputs':1, 'outputs':0},
        'MCP I2C': {'inputs':1, 'outputs':2},
        'Card detect/SPDIF': {'inputs':1, 'outputs':1},
        'LED indicators': {'inputs':0, 'outputs':3},
        'Analog video/SD mux': {'inputs':0, 'outputs':6},
        'Analog sync/SD chip select mux': {'inputs':0, 'outputs':1},
        'USER optional audio': {'inputs':0, 'outputs':3},
    }
    assert sum(g['inputs'] for g in groups.values()) == 20
    assert sum(g['outputs'] for g in groups.values()) == 85
    save('endpoint_inventory.json', {'scope':'Original complete sound-ROM-reader fitted image, report only; no electrical qualification.', 'report_path':str(REPORT), 'report_sha256':expected_report, 'report_lines':[1403,1556], 'unconstrained_inputs':inputs, 'unconstrained_outputs':outputs, 'groups':groups})
    save('source_pins.json', {'canonical_root':str(ROOT), 'fitted_root':str(FIT), 'sources':pins, 'report':{'path':str(REPORT),'sha256':expected_report}})
    save('source_excerpts.json', excerpts)
    (STAGE/'ucp_report_excerpt.txt').write_text('\n'.join(f'{n+1}: {rows[n]}' for n in range(1402,1556))+'\n', encoding='utf-8', newline='\n')
    save('official_sources.json', [
        {'url':'https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf', 'document':'ADV7513 Rev B, May 2014', 'pages':[3,4], 'facts':{'video_setup_ns':1.8,'video_hold_ns':1.3,'i2s_setup_ns':2,'i2s_hold_ns':2,'lrclk_setup_ns':2,'lrclk_hold_ns':2,'i2c_max_khz':400}, 'limits':'Receiver minima only. PCB skew, configuration, modes and I/O load remain unresolved; video relationship programmable in 400ps steps.'},
        {'url':'https://ww1.microchip.com/downloads/en/DeviceDoc/22121a.pdf','document':'Microchip MCP23009/MCP23S09 DS22121A, 2008','pages':[35,36], 'facts':{'fast_mode_high_min_us':0.6,'fast_mode_low_min_us':1.3,'fast_mode_data_setup_min_ns':100,'fast_mode_output_valid_max_ns':900},'limits':'Do not apply high-speed-mode limits without mode/electrical qualification. Observed framework nominal 500kHz cadence gives 1us low time, below this fast-mode guaranteed low minimum; historical compatibility does not qualify this profile.'},
        {'url':'https://www.terasic.com.cn/cgi-bin/page/archive.pl?CategoryNo=205&Language=English&No=1046&PartNo=4','document':'Official DE10-Nano resources listing','facts':'Separate manuals/CDs for hardware A/B, B2/C and E.', 'limits':'Target revision unknown; no PCB trace timing bounds inferred from a manual for an arbitrary revision.'},
        {'url':'https://mister-devel.github.io/MkDocs_MiSTer/developer/emu/','document':'Official MiSTer emu interface','facts':'External SDRAM specifications and module schematic are required for full understanding; module capacity alone is not an electrical timing profile.'},
        {'url':'https://cdrdv2-public.intel.com/654662/tclscriptrefmnl.pdf','document':'Altera Quartus II scripting reference, July 2013','facts':'Output max/min delays constrain setup/hold separately; generated-clock reference accounts for clock arrival; multiple references require add_delay.', 'limits':'Search excerpt inspected; direct web open unavailable. Check installed Quartus17 help before implementation.'},
        {'url':'https://www.intel.com/content/dam/support/us/en/programmable/support-resources/fpga-wiki/asset01/source-synchronous-timing.pdf','document':'Altera Source Synchronous Timing, 2011','facts':'A forwarded DDIO clock physically inverted relative to internal launch clock needs the matching inversion represented in generated-clock constraints.', 'limits':'Search excerpt inspected; direct fetch redirected to unavailable page. Actual clock waveform still must be confirmed in TimeQuest.'},
    ])
    receipts = ['endpoint_inventory.json','source_pins.json','source_excerpts.json','ucp_report_excerpt.txt','official_sources.json','findings.md','constraint_proposal.txt','materialize.py']
    manifest = {'scope':'Read-only investigation; no RTL/SDC/QSF changes, Quartus/hardware/replay jobs or system configuration changes.', 'files':[{'relative_path':n, 'sha256':sha(STAGE/n),'bytes':(STAGE/n).stat().st_size} for n in receipts]}
    save('import_manifest.json', manifest)
    print(json.dumps({'status':'PASS', 'inputs':len(inputs),'outputs':len(outputs),'source_pins':len(pins),'manifest_sha256':sha(STAGE/'import_manifest.json'),'mismatched_fitted_sources':[p['relative_path'] for p in pins if p.get('canonical_matches_fitted_bytes') is False]}))

if __name__ == '__main__':
    main()
