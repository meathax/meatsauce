#!/usr/bin/env python3
"""Source-snapshot Quartus board checks. Never invokes assembler or makes an RBF."""
import argparse
import ast
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import time
from timing_audit import audit

# Shared global Quartus routing: native stages require a registered whole-job recipe.
import hashlib as _sq_hashlib
import os as _sq_os
import pathlib as _sq_pathlib
import re as _sq_re

def _sq_qpf_guard(cwd, revision):
    if not isinstance(revision, str) or not _sq_re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", revision):
        raise RuntimeError("Shared Quartus queue: invalid project/revision")
    root = _sq_pathlib.Path(cwd)
    if not root.is_absolute():
        raise RuntimeError("Shared Quartus queue: absolute project root required")
    qpf = root / (revision + ".qpf")
    for part in (qpf, *qpf.parents):
        if part.is_symlink() or (part.exists() and getattr(part.lstat(), "st_file_attributes", 0) & 0x400):
            raise RuntimeError("Shared Quartus queue: reparse project refused")
    with qpf.open("rb") as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise RuntimeError("Shared Quartus queue: QPF size exceeded")
    revisions = _sq_re.findall(r'^\s*PROJECT_REVISION\s*=\s*"([A-Za-z0-9_.-]+)"\s*$', raw.decode("utf-8-sig"), _sq_re.M)
    if revisions != [revision]:
        raise RuntimeError("Shared Quartus queue: project must equal the sole QPF revision")
    return {"bytes": len(raw), "sha256": _sq_hashlib.sha256(raw).hexdigest()}

def _sq_route_checked(execute, *args, **kwargs):
    command = args[0] if args else kwargs.get("args")
    tokens = list(command) if isinstance(command, (list, tuple)) else None
    native = _sq_re.compile(r'^(?:quartus_(?:sh|map|fit|sta|asm|eda|cdb|pow)|qsys-(?:script|generate))(?:\.exe)?$', _sq_re.I)
    if tokens:
        basename = str(tokens[0]).replace("\\", "/").rsplit("/", 1)[-1]
        is_native = bool(native.fullmatch(basename))
    else:
        is_native = isinstance(command, str) and bool(_sq_re.search(r'\b(?:quartus_(?:sh|map|fit|sta|asm|eda|cdb|pow)|qsys-(?:script|generate))(?:\.exe)?\b', command, _sq_re.I))
    if not is_native:
        return execute(*args, **kwargs)
    cwd = kwargs.get("cwd", _sq_os.getcwd())
    if tokens and basename.lower() in {"quartus_sh", "quartus_sh.exe"} and tokens[1:] == ["--version"]:
        replacement = [r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", r"C:\Users\meath\.claude\skills\mister-rbf-build\scripts\quartus_flow.ps1", "-Action", "Version", "-ProjectRoot", str(_sq_pathlib.Path(cwd).absolute())]
    elif tokens and len(tokens) == 6 and tokens[1:3] == ["--flow", "compile"] and tokens[4] == "-c" and tokens[3] == tokens[5]:
        _sq_qpf_guard(cwd, tokens[3])
        output = kwargs.get("stdout")
        outer = getattr(output, "name", None)
        suffix = ".queue-launch.log"
        if not isinstance(outer, str) or not outer.endswith(suffix):
            raise RuntimeError("Shared Quartus queue: full compile requires an owned native log and queue-launch log adapter")
        helper = _sq_pathlib.Path(r"C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_full_compile.py")
        raw = helper.read_bytes()
        if len(raw) != 2883 or _sq_hashlib.sha256(raw).hexdigest() != "f72df4cd9c291947a026fb0dec80d8f66650f9d6eacc522ca9b1e4277fb4c86e":
            raise RuntimeError("Shared Quartus queue: canonical helper identity changed")
        replacement = [r"D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe", "-B", "-X", "utf8", str(helper), "--cwd", str(cwd), "--revision", tokens[3], "--log", outer[:-len(suffix)]]
    else:
        raise RuntimeError("Shared Quartus queue: standalone or mixed stages are refused; use quartus_flow.ps1 -Action Start with a reviewed complete -RecipeId. Version/provider reads use -Action Version. This refusal does not authorize assembly.")
    if args:
        return execute(replacement, *args[1:], **kwargs)
    return execute(**dict(kwargs, args=replacement))


ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--target', choices=['boot_probe', 'sdram', 'ddr_rom', 'memory_fabric', 'physical_boot', 'mister_rom_loader', 'host_boot'], default='boot_probe', help='actual RTL source set to analyze and fit')
    ap.add_argument('--fit', action='store_true', help='also fit and run static timing analysis')
    ap.add_argument('--registered-interfaces', action='store_true', help='model synchronous registered producers/consumers for isolated core timing; exclude synthetic bench pin segments')
    ap.add_argument('--fit-from', help='fit/STA an unchanged successful analysis snapshot without repeating synthesis')
    ap.add_argument('--sta-from', help='rerun STA against an unchanged successful fit without repeating map/fit')
    ap.add_argument('--quartus-bin', default='D:/q17/quartus/bin64')
    args = ap.parse_args()
    if args.fit_from and args.sta_from:
        ap.error('choose only one resumption mode')
    resume = args.fit_from or args.sta_from
    # Obtain the actual production-default board sources used by boot_probe,
    # without importing sim.py (which is a command-line runner).
    tree = ast.parse((ROOT / 'scripts/sim.py').read_text(encoding='utf-8'))
    entries = [ast.literal_eval(v) for n in ast.walk(tree) if isinstance(n, ast.Dict)
               for k, v in zip(n.keys, n.values)
               if isinstance(k, ast.Constant) and k.value == args.target]
    if len(entries) != 1:
        raise RuntimeError('cannot identify the requested RTL source set')
    files = entries[0]['files']
    core_top = entries[0]['top']
    clock_outputs = entries[0].get('clock_outputs', {})
    if resume:
        args.fit = True
        stage = pathlib.Path(resume).resolve()
        if (ROOT / 'sim/obj_dir/timing').resolve() not in stage.parents:
            raise RuntimeError('fit-from snapshot must be inside this project timing directory')
        saved = json.loads((stage / 'check_report.json').read_text(encoding='utf-8'))
        if saved.get('simulation_target', 'boot_probe') != args.target:
            raise RuntimeError('resumption target differs')
        if args.registered_interfaces and saved.get('interface_model') != 'registered_boundary':
            raise RuntimeError('resumption interface model differs')
        args.registered_interfaces = saved.get('interface_model') == 'registered_boundary'
        if set(saved['source_sha256']) != set(files):
            raise RuntimeError('resumption source set differs')
        if args.fit_from and saved.get('status') != 'SYNTHESIS_PASS':
            raise RuntimeError('fit-from requires successful analysis')
        if args.sta_from and not any(x['tool']=='quartus_fit' and x['returncode']==0 and not x['errors'] for x in saved['steps']):
            raise RuntimeError('sta-from requires a successful fit')
        for n, digest in saved['configuration_sha256'].items():
            if hashlib.sha256((stage / n).read_bytes()).hexdigest() != digest:
                raise RuntimeError('fit-from configuration changed: ' + n)
    else:
        stage = ROOT / 'sim/obj_dir/timing' / str(time.time_ns())
        stage.mkdir(parents=True)
    hashes = {}
    for name in files:
        target = stage / name
        if resume:
            expected = saved['source_sha256'][name]
            if any(hashlib.sha256(f.read_bytes()).hexdigest() != expected for f in [ROOT / name, target]):
                raise RuntimeError('fit-from RTL changed: ' + name)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    ports = []
    declarations = []
    direction, dimensions = None, ''
    module_pattern = r'\bmodule\s+' + re.escape(core_top) + r'\b'
    core_source = next(stage / n for n in files if re.search(module_pattern, (stage / n).read_text()))
    text = core_source.read_text()
    cursor = re.search(module_pattern, text).end()
    def closing_parenthesis(start):
        depth = 0
        for index in range(start, len(text)):
            if text[index] == '(':
                depth += 1
            elif text[index] == ')':
                depth -= 1
                if not depth:
                    return index
        raise RuntimeError('unterminated module header')
    cursor = next(i for i in range(cursor, len(text)) if not text[i].isspace())
    if text[cursor] == '#':
        cursor = closing_parenthesis(text.index('(', cursor)) + 1
    opening = text.index('(', cursor)
    header = text[opening + 1:closing_parenthesis(opening)]
    bus = False
    for declaration in header.split(','):
        explicit = re.search(r'\b(input|output)\b', declaration)
        if explicit:
            direction = explicit.group(1)
            dimensions = ''.join(re.findall(r'\[[^]]+\]', declaration))
            bus = bool(dimensions)
        name = re.search(r'(\w+)\s*$', declaration)
        if not name:
            raise RuntimeError('cannot identify board port: ' + declaration)
        ports.append(name.group(1) + ('*' if bus else ''))
        declarations.append((direction, dimensions, name.group(1)))
    top = 'cs_timing_registered' if args.registered_interfaces else core_top
    if args.registered_interfaces and not resume:
        boundary = ['// Synthetic timing bench; registered core interfaces, no physical I/O claim.',
                    'module cs_timing_registered (',
                    ',\n'.join('    ' + d + ' logic ' + width + ' ' + name
                                for d, width, name in declarations), ');']
        for d, width, name in declarations:
            if name != 'clk':
                boundary.append('    logic ' + width + ' core_' + name + ';')
        boundary += ['    always_ff @(posedge clk) begin']
        for d, width, name in declarations:
            if name != 'clk' and name not in clock_outputs:
                boundary.append('        ' + ('core_' + name + ' <= ' + name if d == 'input'
                                 else name + ' <= core_' + name) + ';')
        boundary.append('    end')
        # Forward actual clock outputs. Sampling an inverted clock with a data
        # flop invents a half-cycle path that is absent from the actual core.
        for name in clock_outputs:
            boundary.append('    assign ' + name + ' = core_' + name + ';')
        boundary += ['    ' + core_top + ' core (',
                     ',\n'.join('        .' + name + '(' + ('clk' if name == 'clk' else 'core_' + name) + ')'
                                 for d, width, name in declarations), '    );', 'endmodule']
        (stage / 'board_registered.sv').write_text('\n'.join(boundary) + '\n', encoding='utf-8')
    qsf = '\n'.join([
        'set_global_assignment -name FAMILY "Cyclone V"',
        'set_global_assignment -name DEVICE 5CSEBA6U23I7',
        'set_global_assignment -name TOP_LEVEL_ENTITY ' + top,
        'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files',
        'set_global_assignment -name SEED 1',
        'set_global_assignment -name NUM_PARALLEL_PROCESSORS 4',
        'set_global_assignment -name SDC_FILE board.sdc',
        *['set_instance_assignment -name VIRTUAL_PIN ON -to ' + n for n in ports],
        *['set_global_assignment -name SYSTEMVERILOG_FILE ' + n for n in files],
        *(['set_global_assignment -name SYSTEMVERILOG_FILE board_registered.sv'] if args.registered_interfaces else []),
    ]) + '\n'
    # Single board clock: CPU ce is an enable, never a generated clock.
    # External interface budgets are provisional until the real backend is wired.
    sdc = ('create_clock -name board_clk -period 11.640 [get_ports {clk}]\n'
           'derive_clock_uncertainty\n'
           'set_input_delay -clock board_clk -max 2.000 [remove_from_collection [all_inputs] [get_ports {clk}]]\n'
           'set_input_delay -clock board_clk -min 0.000 [remove_from_collection [all_inputs] [get_ports {clk}]]\n'
           'set_output_delay -clock board_clk -max 2.000 [all_outputs]\n'
           'set_output_delay -clock board_clk -min 0.000 [all_outputs]\n')
    if args.registered_interfaces:
        # All actual core interfaces are launched/captured by bench registers.
        # Only synthetic pin-to-bench-register and bench-register-to-pin segments
        # are excluded. There are no exceptions through the cs_boot_probe core.
        sdc = ('create_clock -name board_clk -period 11.640 [get_ports {clk}]\n'
               'derive_clock_uncertainty\n'
               'set_false_path -from [remove_from_collection [all_inputs] [get_ports {clk}]]\n'
               'set_false_path -to [all_outputs]\n')
    for name, clock in clock_outputs.items():
        declaration = next(d for d, width, n in declarations if n == name)
        if declaration != 'output':
            raise RuntimeError('declared forwarded clock is not an output: ' + name)
        generated = ('create_generated_clock -name ' + name + ' -source [get_ports {' +
                     clock['source'] + '}] ' + ('-invert ' if clock.get('invert') else '') +
                     '-divide_by 1 [get_ports {' + name + '}]\n')
        sdc = sdc.replace('derive_clock_uncertainty\n', generated + 'derive_clock_uncertainty\n')
    if not resume:
        (stage / 'board.qpf').write_text('PROJECT_REVISION = "board"\n', encoding='utf-8')
        (stage / 'board.qsf').write_text(qsf, encoding='utf-8')
        (stage / 'board.sdc').write_text(sdc, encoding='utf-8')
    scope = (core_top + ' RTL with synthetic synchronous registered interface boundaries; excludes bench pin segments and production wrapper/PLL/physical I/O closure'
             if args.registered_interfaces else
             core_top + ' RTL, virtual pins, provisional 2 ns external interface budget; excludes MiSTer wrapper/PLL/physical I/O closure')
    report = dict(scope=scope, top_entity=top,
                  simulation_target=args.target,
                  interface_model='registered_boundary' if args.registered_interfaces else 'provisional_external',
                  stage=str(stage), source_sha256=hashes, clock_period_ns=11.640,
                  seed=1, rbf_generated=False, requested_fit=args.fit, steps=[])
    report['configuration_sha256'] = {n: hashlib.sha256((stage / n).read_bytes()).hexdigest()
                                      for n in ['board.qpf', 'board.qsf', 'board.sdc'] +
                                      (['board_registered.sv'] if args.registered_interfaces else [])}
    if resume:
        report = saved
        report['requested_fit'] = True
    print('TIMING_SNAPSHOT ' + str(stage), flush=True)
    # Shared guard: no JTAG overlap with Quartus tools.
    _sq_route_checked(subprocess.run, [sys.executable, str(ROOT / 'scripts/hwlock.py'), '--require-no-jtag',
                    'check_timing board RTL'], cwd=ROOT, check=True)
    tools = (['quartus_sta'] if args.sta_from else
             ([] if args.fit_from else ['quartus_map']) + (['quartus_fit', 'quartus_sta'] if args.fit else []))
    for tool in tools:
        cmd = [str(pathlib.Path(args.quartus_bin) / (tool + '.exe')),
               '--read_settings_files=on', '--write_settings_files=off', 'board', '-c', 'board']
        if tool == 'quartus_sta':
            cmd = [cmd[0], 'board', '-c', 'board']
        log = stage / (tool + '.log')
        if log.exists():
            archived = stage / (tool + '.attempt' + str(len(report['steps'])) + '.log')
            shutil.copyfile(log, archived)
            for previous in report['steps']:
                if previous['log'] == str(log):
                    previous['log'] = str(archived)
        started = time.monotonic()
        with log.open('w', encoding='utf-8') as output:
            proc = _sq_route_checked(subprocess.Popen, cmd, cwd=stage, stdout=output, stderr=subprocess.STDOUT)
            print('QUARTUS_PID ' + tool + ' ' + str(proc.pid), flush=True)
            result = subprocess.CompletedProcess(cmd, proc.wait())
        lines = log.read_text(encoding='utf-8', errors='replace').splitlines()
        errors = [x for x in lines if re.match(r'\s*(?:Error|Fatal Error)\b', x)]
        report['steps'].append(dict(tool=tool, returncode=result.returncode,
                                    seconds=round(time.monotonic() - started, 3),
                                    errors=errors[:12], log=str(log)))
        print(json.dumps(report['steps'][-1]), flush=True)
        if result.returncode or errors:
            report['status'] = 'FAIL'
            break
    else:
        report['status'] = 'SYNTHESIS_PASS'
        if args.fit:
            summary = stage / 'output_files/board.sta.summary'
            text = summary.read_text(errors='replace') if summary.exists() else ''
            slacks = [float(x) for x in re.findall(r'Slack\s*:\s*(-?\d+(?:\.\d+)?)', text)]
            report['timing_summary'] = text
            report['slacks_ns'] = slacks
            report['status'] = ('TIMING_PASS' if slacks and min(slacks) >= 0
                                and 'Setup' in text and 'Hold' in text else 'TIMING_FAIL')
            fit = stage / 'output_files/board.fit.summary'
            report['resources'] = fit.read_text(errors='replace') if fit.exists() else ''
            try:
                report['path_audit'] = audit(stage, args.quartus_bin)
            except (OSError, RuntimeError, ValueError) as error:
                report['path_audit'] = dict(status='AUDIT_ERROR', errors=[str(error)])
            if report['path_audit']['status'] != 'AUDIT_PASS':
                report['status'] = 'TIMING_FAIL'
    changed_inputs = [name for name, digest in {**hashes, **report['configuration_sha256']}.items()
                      if hashlib.sha256((stage / name).read_bytes()).hexdigest() != digest]
    if changed_inputs:
        report['status'] = 'FAIL'
        report['changed_snapshot_inputs'] = changed_inputs
    path = stage / 'check_report.json'
    path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if 'path_audit' in report:
        # Surface the evidence needed for the next RTL decision even when the
        # timing check exits nonzero; full paths/hashes remain in the report.
        print('TIMING_CORNERS ' + json.dumps({
            'fully_constrained': report['path_audit'].get('fully_constrained'),
            'corners': [{'model': c['model'], 'setup': c['setup'],
                         'hold_slack_ns': c['hold']['slack_ns']}
                        for c in report['path_audit'].get('corners', [])]
        }), flush=True)
    print('TIMING_RESULT ' + report['status'] + ' ' + str(path), flush=True)
    return 0 if report['status'] in ['SYNTHESIS_PASS', 'TIMING_PASS'] else 1


if __name__ == '__main__':
    sys.exit(main())
