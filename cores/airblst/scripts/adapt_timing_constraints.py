#!/usr/bin/env python3
"""Stage conservative Arblst timing repairs; never mutate donor/project inputs.

No compiler, simulator or hardware command is launched. External delays require
an explicit device/board-envelope JSON; absent that file they remain a template.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SDC = ROOT / 'donors/jtcores/modules/jtframe/target/mister/hdl/sys/sys_top.sdc'
AUDIT_TCL_PATH = ROOT / 'scripts/stagedtiming_audit.tcl'
SDC_SHA = '51972b34b6b1255c5246f93edd0269de181f5b60a1d2124576e6fd15a86cda35'
TARGET = ROOT / 'donors/jtcores/modules/jtframe/target/mister'
QSF_TEMPLATE_SHA = '4dcd5384b2a4107ad2a0399d0e375939b8ef19c5a3b86248a58b7457ac26fb1e'
SDRAM_CLOCK_SHA = 'b5b8425ea5e66cba4296a01ade14f2088f80105efe4a1e3a76ad34be92bdd553'
REMOVAL_PREFIX = '# AIRBLAST: removed unproved exception; default timing retained\n# '
PACKING_PREFIX = '# AIRBLAST: removed stale legacy SDRAM capture packing assignment\n# '
LEGACY_EXTERNAL_INCLUDE = '\n# AIRBLAST: explicit allocated Alliance CL2 external timing model.\nsource [file join [file dirname [info script]] arblst_sdram_external.sdc]\n'
EXTERNAL_INCLUDE = LEGACY_EXTERNAL_INCLUDE + 'source [file join [file dirname [info script]] arblst_board_clocks.sdc]\n'
BOARD_CLOCKS = '''# Existing DB15 counter runs unconditionally at the 48MHz system clock.
# Bit3 is divide16, including reset/pause/ROM stalls; no RTL or exception change.
set ab_db15_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set ab_db15_counter [get_registers {*|jtframe_joymux:u_joymux|joy_db15:u_db15|JCLOCKS[3]}]
if {[get_collection_size $ab_db15_source] != 1 || [get_collection_size $ab_db15_counter] != 1} {
    error "AIRBLAST 48MHz DB15 clock source/target mismatch"
}
create_generated_clock -name ARBLST_DB15 -source $ab_db15_source -divide_by 16 $ab_db15_counter
derive_clock_uncertainty
'''
CUTS = (
    'set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2',
    'set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1',
    'set_false_path -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom[0]}] -to [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom_sync}]',
    'set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}',
)
STALE_PACKING = 'set_instance_assignment -name FAST_INPUT_REGISTER ON -to emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|dq_ff -entity sys_top'
DEVICE_URL = 'https://www.alliancememory.com/wp-content/uploads/AllianceMemory_512M_SDRAM_Bdie_AS4C32M16SB-7TXN-6TIN-7BIN__Rev1.4_June2024NK.pdf'
DEVICE_SHA = '2cdfcb4b2fab106ae55eb4cb9ea27a60795ed1bb14745c0516d5eb7e836954f6'
SUPPORTED_PROFILE = {
    'name': 'Alliance-CL2-48MHz-allocated-1ns-trace-envelope-v1',
    'device': 'AS4C32M16SB-7',
    'covered_device_envelope': ['AS4C32M16SB-6', 'AS4C32M16SB-7', 'AS4C16M16SA-6', 'AS4C16M16SA-7'],
    'disposition': 'supported-envelope-requirement',
    'evidence': 'Root engineering allocation: each clock, DQ and command/address path 0..1ns; output trace skew -1..+1ns. Requirement, NOT measured PCB evidence. Load/slew must meet named manufacturer datasheet conditions.',
    'clock_flight_min_ns': 0.0, 'clock_flight_max_ns': 1.0,
    'dq_flight_min_ns': 0.0, 'dq_flight_max_ns': 1.0,
    'command_flight_min_ns': 0.0, 'command_flight_max_ns': 1.0,
    'external_uncertainty_ns': 0.0,
    'load_and_slew_within_datasheet_conditions': True,
}


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def repair_sdc(raw: bytes) -> bytes:
    if sha(raw) != SDC_SHA:
        raise ValueError('unrecognized sys_top.sdc identity; no candidate written')
    text = raw.decode('utf-8')
    for anchor in CUTS:
        if text.splitlines().count(anchor) != 1:
            raise ValueError('missing/duplicate exact SDC anchor')
        text = text.replace(anchor, REMOVAL_PREFIX + anchor, 1)
    return text.encode('utf-8')


def repair_qsf(raw: bytes, expected: str) -> bytes:
    if sha(raw) != expected:
        raise ValueError('QSF source seal mismatch')
    text = raw.decode('utf-8')
    if text.splitlines().count(STALE_PACKING) != 1:
        raise ValueError('missing/duplicate legacy input packing assignment')
    return text.replace(STALE_PACKING, PACKING_PREFIX + STALE_PACKING, 1).encode('utf-8')


def original_sdc(raw: bytes) -> bytes:
    """Admit exactly the original or this recipe's entire recognized candidate."""
    text = raw.decode('utf-8')
    for anchor in CUTS:
        text = text.replace(REMOVAL_PREFIX + anchor, anchor)
    original = text.encode('utf-8')
    # Admit the previous three-cut installation only by reproducing its exact
    # bytes from the immutable donor; no arbitrary intermediate edit is allowed.
    previous = original.decode('utf-8')
    for anchor in CUTS[:-1]:
        previous = previous.replace(anchor, REMOVAL_PREFIX + anchor, 1)
    if sha(original) != SDC_SHA or raw not in (original, previous.encode('utf-8'), repair_sdc(original)):
        raise ValueError('unrecognized original/installed sys_top.sdc')
    return original


def installation_plan() -> dict[Path, bytes]:
    """Validate every original/candidate before the first installation write."""
    source = original_sdc(SDC.read_bytes())
    qsf_path = TARGET/'mister.qsf'
    qsf_raw = qsf_path.read_bytes()
    qsf_original = qsf_raw.decode('utf-8').replace(PACKING_PREFIX+STALE_PACKING, STALE_PACKING).encode('utf-8')
    qsf_candidate = repair_qsf(qsf_original, QSF_TEMPLATE_SHA)
    if qsf_raw not in (qsf_original, qsf_candidate):
        raise ValueError('unrecognized QSF template candidate')
    clock_path = TARGET/'syn/sdram_clk48.sdc'
    clock_raw = clock_path.read_bytes()
    clock_original = clock_raw.removesuffix(EXTERNAL_INCLUDE.encode()).removesuffix(LEGACY_EXTERNAL_INCLUDE.encode())
    if sha(clock_original) != SDRAM_CLOCK_SHA:
        raise ValueError('unrecognized SDRAM clock source')
    clock_candidate = clock_original+EXTERNAL_INCLUDE.encode()
    if clock_raw not in (clock_original, clock_original+LEGACY_EXTERNAL_INCLUDE.encode(), clock_candidate):
        raise ValueError('unrecognized SDRAM clock candidate')
    external, _ = external_model(dict(SUPPORTED_PROFILE))
    external_path = TARGET/'syn/arblst_sdram_external.sdc'
    if external_path.exists() and external_path.read_bytes() != external.encode():
        raise ValueError('refuse overwriting unrelated external timing model')
    # Source-bound proof of the existing divider; this is not a new clock.
    joy_path=TARGET/'hdl/joydb15.v'
    if sha(joy_path.read_bytes()) != '71f4a6b717b2d55397ee6f8cd7b660146dad4f2f8a4e0cb21919c7d83f9f5b02':
        raise ValueError('DB15 counter source differs from reviewed unconditional divide16')
    board_path=TARGET/'syn/arblst_board_clocks.sdc'
    if board_path.exists() and board_path.read_bytes()!=BOARD_CLOCKS.encode():
        raise ValueError('refuse overwriting unrelated board clocks')
    return {SDC:repair_sdc(source), qsf_path:qsf_candidate,
            external_path:external.encode(), clock_path:clock_candidate,board_path:BOARD_CLOCKS.encode()}


def install_sources() -> dict:
    plan = installation_plan()
    receipt = {'recipe':'scripts/adapt_timing_constraints.py --install',
               'status':'installed source constraints; no native timing qualification',
               'profile':SUPPORTED_PROFILE,
               'files':{str(p.relative_to(ROOT)).replace('\\','/'):
                        {'before':sha(p.read_bytes()) if p.exists() else None,'after':sha(b)} for p,b in plan.items()}}
    for p, raw in plan.items():
        if not p.exists() or p.read_bytes() != raw:
            p.write_bytes(raw)
    verify_installation()
    (ROOT/'docs/timing-constraint-installation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def verify_installation() -> None:
    for p, raw in installation_plan().items():
        if p.read_bytes() != raw:
            raise ValueError('timing source installation incomplete: '+str(p))


def refresh_generated_qsf(path: Path) -> dict:
    """Parent generation hook: preserve all unrelated project-specific settings.

    Called only after strict source-install verification. Accepts precisely one
    legacy assignment or precisely one known commented replacement, never both.
    """
    verify_installation()
    raw = path.read_bytes()
    text = raw.decode('utf-8')
    active = text.splitlines().count(STALE_PACKING)
    known = text.count(PACKING_PREFIX+STALE_PACKING)
    if (active, known) == (1, 0):
        candidate = repair_qsf(raw, sha(raw))
    elif (active, known) == (0, 1):
        candidate = raw
    else:
        raise ValueError('generated QSF missing/duplicate/unknown packing disposition')
    # Quartus 17 map crashed with eight threads on the sealed source graph;
    # the identical graph mapped with one thread. Preserve all optimizations.
    qsf_text = candidate.decode('utf-8')
    thread_assignment = r'(?m)^set_global_assignment -name NUM_PARALLEL_PROCESSORS \S+$'
    matches = re.findall(thread_assignment, qsf_text)
    if len(matches) > 1:
        raise ValueError('duplicate compiler thread assignment')
    if matches:
        qsf_text = re.sub(thread_assignment, 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1', qsf_text)
    else:
        qsf_text += '\nset_global_assignment -name NUM_PARALLEL_PROCESSORS 1\n'
    capture_flag = 'JTARBLST_SDRAM_CAPTURE'
    capture_files = [ROOT/'donors/jtcores/modules/jtframe'/name for name in (
        'hdl/sdram/jtframe_sdram64.v', 'hdl/jtframe_board_sdram.v',
        'hdl/jtframe_board.v', 'target/mister/hdl/jtframe_mister.sv')]
    capture_installed = [capture_flag in p.read_text(encoding='utf-8') for p in capture_files]
    if any(capture_installed) and not all(capture_installed):
        raise ValueError('Partial physical DQ-capture installation')
    if all(capture_installed):
        assignment = 'set_global_assignment -name VERILOG_MACRO "JTARBLST_SDRAM_CAPTURE=1"'
        matching = [line for line in qsf_text.splitlines() if capture_flag in line]
        if matching and matching != [assignment]:
            raise ValueError('Unknown/duplicate physical DQ-capture selection')
        if not matching:
            qsf_text += '\n'+assignment+'\n'
    candidate = qsf_text.encode('utf-8')
    if candidate != raw:
        path.write_bytes(candidate)
    return {'path':str(path),'before':sha(raw),'after':sha(candidate)}


def external_model(profile: dict) -> tuple[str, dict]:
    if profile.get('device') not in tuple(SUPPORTED_PROFILE['covered_device_envelope']):
        raise ValueError('only explicitly researched Alliance -6/-7 device envelopes supported')
    # Values are declared envelope requirements/evidence, never guessed defaults.
    if profile.get('disposition') not in ('supported-envelope-requirement', 'board-evidence'):
        raise ValueError('profile must distinguish supported requirement from board evidence')
    if not isinstance(profile.get('evidence'), str) or len(profile['evidence'].strip()) < 12:
        raise ValueError('board/trace/load envelope evidence or requirement description missing')
    vals = {}
    for key in ('clock_flight_min_ns', 'clock_flight_max_ns', 'dq_flight_min_ns', 'dq_flight_max_ns',
                'command_flight_min_ns', 'command_flight_max_ns', 'external_uncertainty_ns'):
        value = profile.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value < 0:
            raise ValueError('finite explicit nonnegative bound required: ' + key)
        vals[key] = float(value)
    for net in ('clock', 'dq', 'command'):
        if vals[net + '_flight_min_ns'] > vals[net + '_flight_max_ns']:
            raise ValueError('reversed trace envelope: ' + net)
    if profile.get('load_and_slew_within_datasheet_conditions') is not True:
        raise ValueError('datasheet load/slew applicability must be stated')
    cmin, cmax = vals['clock_flight_min_ns'], vals['clock_flight_max_ns']
    dmin, dmax = vals['dq_flight_min_ns'], vals['dq_flight_max_ns']
    amin, amax = vals['command_flight_min_ns'], vals['command_flight_max_ns']
    u = vals['external_uncertainty_ns']
    # Table16 CL2: tAC<=6ns, input setup>=1.5ns, hold>=0.8ns.
    # Use min=0 rather than tOH=2.5: conservatively includes burst-end Hi-Z.
    limits = {'input_max': cmax + 6.0 + dmax + u, 'input_min': cmin + dmin - u,
              'dq_output_max': 1.5 + dmax - cmin + u,
              'dq_output_min': dmin - cmax - 0.8 - u,
              'command_output_max': 1.5 + amax - cmin + u,
              'command_output_min': amin - cmax - 0.8 - u}
    lines = ['# Explicit Alliance AS4C32M16SB/AS4C16M16SA -6/-7 CL2 model; profile in manifest.json.',
             '# Reference is the existing forwarded physical SDRAM_CLK pad clock.',
             '# No multicycle, clock cut, phase change, or inferred board measurement.',
             'if {[get_collection_size [get_clocks SDRAM_CLK]] != 1} {error "required SDRAM_CLK missing/ambiguous"}',
             'set ab_dq [get_ports {SDRAM_DQ[*]}]',
             'set ab_ca [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]',
             'if {[get_collection_size $ab_dq] != 16} {error "expected sixteen DQ ports"}',
             'if {[get_collection_size $ab_ca] != 22} {error "expected twenty-two command/address/mask/CKE ports"}']
    for mode in ('max', 'min'):
        lines.extend((f'set_input_delay -clock SDRAM_CLK -{mode} {limits["input_"+mode]:.9f} $ab_dq',
                      f'set_output_delay -clock SDRAM_CLK -{mode} {limits["dq_output_"+mode]:.9f} $ab_dq',
                      f'set_output_delay -clock SDRAM_CLK -{mode} {limits["command_output_"+mode]:.9f} $ab_ca'))
    return '\n'.join(lines) + '\n', limits


# The standalone Quartus 17 audit source is also copied into each candidate.


def self_test() -> None:
    raw = original_sdc(SDC.read_bytes())
    candidate = repair_sdc(raw).decode()
    assert all(candidate.splitlines().count(x) == 0 for x in CUTS)
    assert len([x for x in candidate.splitlines() if x.startswith('# AIRBLAST:')]) == len(CUTS)
    assert original_sdc(candidate.encode()) == raw
    try:
        original_sdc(candidate.encode()+b'\n')
    except ValueError:
        pass
    else:
        raise AssertionError('changed installed identity accepted')
    try:
        repair_sdc(raw + b'\n')
    except ValueError:
        pass
    else:
        raise AssertionError('mutated SDC accepted')
    q = (STALE_PACKING + '\n').encode()
    assert repair_qsf(q, sha(q)).decode().splitlines().count(STALE_PACKING) == 0
    for bad, digest in ((q, '0'*64), (q+q, sha(q+q))):
        try:
            repair_qsf(bad, digest)
        except ValueError:
            pass
        else:
            raise AssertionError('bad QSF accepted')
    profile = {'device': 'AS4C32M16SB-7', 'disposition': 'supported-envelope-requirement',
               'evidence': 'Synthetic arithmetic test; NOT board evidence',
               'load_and_slew_within_datasheet_conditions': True,
               **{x+'_flight_'+k+'_ns': float(k=='max') for x in ('clock','dq','command') for k in ('min','max')},
               'external_uncertainty_ns': 0.0}
    _, v = external_model(profile)
    assert v == {'input_max':8.0,'input_min':0.0,'dq_output_max':2.5,'dq_output_min':-1.8,'command_output_max':2.5,'command_output_min':-1.8}
    for mutate in ({'clock_flight_min_ns': 2.0}, {'external_uncertainty_ns': float('nan')},
                   {'device':'unknown'}, {'load_and_slew_within_datasheet_conditions':False}):
        try:
            external_model({**profile, **mutate})
        except ValueError:
            pass
        else:
            raise AssertionError('invalid external profile accepted')
    print('PASS: exact four-cut repair; source/QSF/duplicate negatives; external-model arithmetic and four invalid-profile controls')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=ROOT/'build/timing-constraint-candidate')
    ap.add_argument('--qsf', type=Path)
    ap.add_argument('--expect-qsf-sha')
    ap.add_argument('--external-profile', type=Path)
    ap.add_argument('--supported-profile', action='store_true', help='explicit allocated 0..1ns trace requirement, not measured evidence')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--install', action='store_true', help='install exact source-guarded constraints; no build')
    ap.add_argument('--verify-installed', action='store_true')
    ap.add_argument('--refresh-generated-qsf', type=Path, help='strict verified-generation hook; removes only legacy packing assignment')
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return
    if a.install:
        receipt = install_sources()
        print(json.dumps({'status':receipt['status'],'files':list(receipt['files'])}))
        return
    if a.verify_installed:
        verify_installation()
        print('PASS: exact timing source installation verified; no build')
        return
    if a.refresh_generated_qsf:
        print(json.dumps(refresh_generated_qsf(a.refresh_generated_qsf)))
        return
    out = a.out.resolve()
    if not out.is_relative_to((ROOT/'build/timing-constraint-candidate').resolve()):
        raise ValueError('output must stay inside build/timing-constraint-candidate')
    raw = original_sdc(SDC.read_bytes())
    audit_tcl = (ROOT / 'scripts/stagedfitted_constants.tcl').read_bytes() + b'\n' + AUDIT_TCL_PATH.read_bytes()
    staged = {'sys_top.sdc': repair_sdc(raw), 'timing_audit.tcl': audit_tcl,
              'arblst_board_clocks.sdc':BOARD_CLOCKS.encode()}
    manifest = {'status':'UNAPPLIED; source-only, not timing-qualified', 'sdc_source':str(SDC),
                'source_sha256':sha(raw),'audit_tcl_source_sha256':sha(audit_tcl),
                'removed_exact_exceptions':list(CUTS),
                'donor_clocks_phases_unchanged':True, 'external_model_applied':False,
                'device_reference':{'url':DEVICE_URL,'sha256':DEVICE_SHA},
                'additional_device_reference':{'url':'https://www.alliancememory.com/wp-content/uploads/256Mb-AS4C16M16SA-CI_V3.0_March-2015.pdf',
                'sha256':'f30ae7f5d0f5ee73cf536c0b8dda88b0c393615a5fb57bf5c8f037f0c7636fcc'}}
    if bool(a.qsf) != bool(a.expect_qsf_sha):
        raise ValueError('--qsf and --expect-qsf-sha must be supplied together')
    if a.qsf:
        staged['project.qsf.candidate'] = repair_qsf(a.qsf.read_bytes(), a.expect_qsf_sha)
        manifest['qsf_source_sha256'] = a.expect_qsf_sha
    if a.external_profile and a.supported_profile:
        raise ValueError('select one explicit external profile source')
    if a.external_profile or a.supported_profile:
        profile = json.loads(a.external_profile.read_text()) if a.external_profile else dict(SUPPORTED_PROFILE)
        model, limits = external_model(profile)
        staged['sdram_external.sdc'] = model.encode()
        staged['supported-profile.json'] = (json.dumps(profile, indent=2)+'\n').encode()
        manifest.update(external_model_applied=True, external_profile=profile, external_limits_ns=limits,
                        external_profile_sha256=sha(a.external_profile.read_bytes()) if a.external_profile else sha(staged['supported-profile.json']))
    else:
        staged['sdram_external.sdc.template'] = b'# NOT LOADABLE: explicit device/trace/load envelope JSON is required.\n# See docs/timing-constraint-repair.md; no implicit zero-board-delay defaults.\nerror "SDRAM physical envelope unspecified; regenerate with --external-profile"\n'
    manifest['outputs'] = {k:sha(v) for k,v in staged.items()}
    # All identity/schema/anchor validation precedes the first output write.
    out.mkdir(parents=True, exist_ok=True)
    for name, body in staged.items():
        (out/name).write_bytes(body)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'status':manifest['status'],'output':str(out),'external_model_applied':manifest['external_model_applied'],'outputs':list(staged)}))


if __name__ == '__main__':
    main()
