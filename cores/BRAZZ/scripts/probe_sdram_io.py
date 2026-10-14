#!/usr/bin/env python3
"""Measure SDRAM pins on an existing fit using an explicit provisional profile.

Does not change the fitted source, QSF/SDC, or claim production closure. No ASM.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

def _sq_refuse_quartus(recipe):
    raise RuntimeError('Standalone Quartus operations are disabled. Use canonical quartus_flow.ps1 -Action Start -RecipeId '
                       + recipe + ' after the complete recipe is registered. Assembly authority remains separate.')


ROOT = Path(__file__).resolve().parents[1]
TCL = '''package require ::quartus::sta
project_open CrystalSystem
create_timing_netlist
read_sdc
set source [get_pins -compatibility_mode {*pll_inst*general[0]*divclk}]
if {[get_collection_size $source] != 1} {error "expected one core PLL output pin"}
foreach_in_collection pin $source {puts "SDRAM_SOURCE [get_node_info -name $pin]"}
if {[get_collection_size [get_clocks -nowarn {cs_sdram_clk}]] == 1} {
 set memory_clock cs_sdram_clk
} else {
 create_generated_clock -name cs_sdram_probe -source $source -invert [get_ports {SDRAM_CLK}]
 set memory_clock cs_sdram_probe
}
# ISSI L CL2 worst -5/-6; board clock/data one-way flights each 0..0.5 ns.
# The latter are provisional bounds, not measured board values.
set_input_delay -clock $memory_clock -max 7.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock $memory_clock -min 2.7 [get_ports {SDRAM_DQ[*]}]
set outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE}]
set_output_delay -clock $memory_clock -max 2.0 $outputs
set_output_delay -clock $memory_clock -min -1.3 $outputs
update_timing_netlist
file mkdir sdram_io_probe
report_clocks -file sdram_io_probe/clocks.rpt
set waves [open sdram_io_probe/pll_waveforms.txt w]
foreach_in_collection c [get_clocks *] {
 set name [get_clock_info -name $c]
 if {[string match {emu|pll|*} $name]} {
  puts $waves "$name|[get_clock_info -waveform $c]|[get_clock_info -period $c]"
 }
}
close $waves
set corner 0
foreach_in_collection op [get_available_operating_conditions] {
 set_operating_conditions $op
 update_timing_netlist
 report_timing -setup -from [get_ports {SDRAM_DQ[*]}] -npaths 2 -detail full_path -file sdram_io_probe/corner${corner}_input_setup.rpt
 report_timing -hold -from [get_ports {SDRAM_DQ[*]}] -npaths 2 -detail full_path -file sdram_io_probe/corner${corner}_input_hold.rpt
 report_timing -setup -to $outputs -npaths 2 -detail full_path -file sdram_io_probe/corner${corner}_output_setup.rpt
 report_timing -hold -to $outputs -npaths 2 -detail full_path -file sdram_io_probe/corner${corner}_output_hold.rpt
 incr corner
}
project_close -dont_export_assignments
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot')
    args = parser.parse_args()
    stage = Path(args.snapshot).resolve()
    if (ROOT / 'sim/obj_dir/production').resolve() not in stage.parents:
        raise RuntimeError('requires a saved production snapshot in this project')
    summary = (stage / 'output_files/CrystalSystem.fit.summary').read_text()
    if 'Successful' not in summary:
        raise RuntimeError('requires a successful saved fit')
    protected = [stage / 'CrystalSystem.qsf', stage / 'CrystalSystem.sdc']
    original = {p: p.read_bytes() for p in protected}
    script = stage / 'sdram_io_probe.tcl'
    script.write_text(TCL)
    started = time.monotonic()
    log = stage / 'sdram_io_probe.log'
    with log.open('w') as output:
        proc = _sq_refuse_quartus('brazz-sdram-io-complete-diagnostic')
        print('QUARTUS_PID sdram_io_probe ' + str(proc.pid), flush=True)
        code = proc.wait()
    text = log.read_text(errors='replace')
    errors = [x for x in text.splitlines() if re.match(r'\s*(?:Error|Fatal Error)\b', x)][:12]
    result = {'snapshot': str(stage), 'returncode': code, 'errors': errors,
              'seconds': round(time.monotonic() - started, 3), 'log': str(log),
              'scope': 'provisional pin-window diagnosis on saved fit; not production signoff',
              'profile': {'part_family': 'ISSI IS42S16160L', 'cas': 2,
                          'tAC_max_ns': 6.5, 'tOH_min_ns': 2.7,
                          'setup_ns': 1.5, 'hold_ns': 0.8,
                          'clock_flight_ns': [0, 0.5], 'data_flight_ns': [0, 0.5],
                          'board_bounds_measured': False,
                          'source': 'https://www.issi.com/WW/pdf/42-45S83200L-16160L.pdf'},
              'script_sha256': hashlib.sha256(TCL.encode()).hexdigest(), 'paths': []}
    if not code and not errors:
        for path in sorted((stage / 'sdram_io_probe').glob('corner*.rpt')):
            body = path.read_text(errors='replace')
            match = re.search(r'Path #1: (?:Setup|Hold) slack is (-?\d+(?:\.\d+)?)', body)
            if not match:
                raise RuntimeError('missing required SDRAM path: ' + str(path))
            first = body.split('Path #1:', 1)[1]
            item = {'report': str(path), 'slack_ns': float(match.group(1))}
            for key in ('From Node', 'To Node', 'Launch Clock', 'Latch Clock', 'Data Delay'):
                found = re.search(r'; ' + key + r'\s*; ([^;\r\n]+)', first)
                if not found:
                    raise RuntimeError('missing path field ' + key)
                item[key.lower().replace(' ', '_')] = found.group(1).strip()
            result['paths'].append(item)
    # On Tcl errors Quartus auto-closes with an assignment export, even though
    # the successful path uses -dont_export_assignments. Restore exact bytes.
    if result['paths']:
        profiles = []
        for item in result['paths']:
            if '_input_' not in item['report']:
                continue
            first = Path(item['report']).read_text().split('Path #1:', 1)[1].split('Path #2:', 1)[0]
            clock_paths = [float(line.split(';')[2]) for line in first.splitlines()
                           if '; clock path ' in line]
            if len(clock_paths) != 2:
                raise RuntimeError('cannot recover input clock-path difference')
            latest = '_setup' in item['report']
            profiles.append({'name': Path(item['report']).stem,
                             'clock_delta_ns': round(clock_paths[0]-clock_paths[1], 6),
                             'chip_access_ns': 6.5 if latest else 2.7,
                             'input_pad_ns': float(item['data_delay']),
                             'board_return_ns': 1.0 if latest else 0.0})
        result['native_profiles'] = profiles
        waves=[]
        for line in (stage/'sdram_io_probe/pll_waveforms.txt').read_text().splitlines():
            name,wave,period=line.rsplit('|',2)
            waves.append({'name':name,'waveform_ns':[float(v) for v in wave.strip('{} ').split()], 'period_ns':float(period)})
        result['pll_waveforms']=waves
        core=[w for w in waves if 'general[0]' in w['name'] and w['name'].endswith('~PLL_OUTPUT_COUNTER|divclk')]
        capture=[w for w in waves if 'general[1]' in w['name'] and w['name'].endswith('~PLL_OUTPUT_COUNTER|divclk')]
        if len(core)==1 and len(capture)==1:
            result['capture_phase_ns']=(capture[0]['waveform_ns'][0]-core[0]['waveform_ns'][0])%core[0]['period_ns']

        profile_file = stage / 'sdram_io_probe/profiles.txt'
        profile_file.write_text('# source ' + str(stage) + '\n' +
            ('# capture_phase_ns '+str(result['capture_phase_ns'])+'\n' if 'capture_phase_ns' in result else '') +
            '\n'.join(f"{p['name']} {p['clock_delta_ns']} {p['chip_access_ns']} {p['input_pad_ns']} {p['board_return_ns']}"
                      for p in profiles) + '\n')
        result['native_profile_file'] = str(profile_file)
        result['native_profile_sha256'] = hashlib.sha256(profile_file.read_bytes()).hexdigest()
    result['restored_quartus_autoexport'] = []
    for path in protected:
        if path.read_bytes() != original[path]:
            path.write_bytes(original[path])
            result['restored_quartus_autoexport'].append(path.name)
    result['status'] = 'PROBE_ERROR' if code or errors else 'PROBE_COMPLETE'
    (ROOT / 'docs/sdram_pin_window_probe.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('status', 'snapshot', 'seconds', 'errors')}), flush=True)
    for item in result['paths']:
        print(Path(item['report']).name, item['slack_ns'], item['from_node'], '->', item['to_node'])
    return code or int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
