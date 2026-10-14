"""Stage a private MAME observer overlay and build plan. Never compile/run MAME."""
from pathlib import Path
import difflib
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
MAME = Path(r'D:\Arcade\AI\mame289')
OLD = Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
CPU = Path('src/devices/cpu/m68000')
PINS = {
    'm68000.h': '0d11d147b5cedb684fe7256ab9133227003cf535417b0c393b59d7cd6a350157',
    'm68000.cpp': 'ef095e786564a203b828ed8e1e517b6af2e0d8fd64090d432f8be67480a5fab3',
    'm68000gen.py': '0679ed7a9ceae276f67998832af0b998421f7792096ae4932c8cc6cb933e9d33',
}

def pin(p):
    b = p.read_bytes()
    return {'path': str(p), 'sha256': hashlib.sha256(b).hexdigest(), 'bytes': len(b)}

original = {}
for name, expected in PINS.items():
    p = MAME / CPU / name
    assert pin(p)['sha256'] == expected, name
    original[name] = p.read_text()

# Existing public state indices are small positive M68K_* enums. Diagnostic
# indices 0x10000..0x10006 are confined to this private overlay.
entries = '\t// Private diagnostic exports: getters only; no CPU-state imports.\n'
for i, (label, field) in enumerate([
    ('IRQ_PENDING_STATE', 'm_int_next_state'), ('IRQ_NEXT_STATE', 'm_next_state'),
    ('IRQ_LEVEL', 'm_int_level'), ('IRQ_INST_STATE', 'm_inst_state'),
    ('IRQ_INST_SUBSTATE', 'm_inst_substate'), ('IRQ_IRD', 'm_ird'),
    ('IRQ_IRC', 'm_irc'),
]):
    entries += f'\tstate_add(0x{0x10000+i:x}, "{label}", {field}).readonly();\n'

helper = r'''
// Private observer: no cycle deduction, timer scheduling, bus or core-state writes.
void m68000_device::irq_cutoff_observe(const char *event)
{
	const auto lt = local_time().as_ticks(48000000);
	if (strcmp(tag(), ":maincpu") || !((lt >= 47847465 && lt <= 47851465) || (lt >= 47998000 && lt <= 48002000)))
		return;
	logerror("IRQ_CUTOFF,%llu,%s,%llu,%llu,%llu,%d,%u,%u,%u,%u,%u,%u,%u,%u,%u\n",
		static_cast<unsigned long long>(++m_irq_observe_sequence), event,
		static_cast<unsigned long long>(lt),
		static_cast<unsigned long long>(machine().time().as_ticks(48000000)),
		static_cast<unsigned long long>(total_cycles()), m_icount,
		m_pc, m_ipc, m_ir, m_ird, m_irc, m_sr,
		m_int_level, m_int_next_state, m_next_state);
}
'''

modified = dict(original)
anchor = '\tset_icountptr(m_icount);'
assert modified['m68000.cpp'].count(anchor) == 1
modified['m68000.cpp'] = modified['m68000.cpp'].replace(anchor, entries + '\n' + anchor)
anchor = '\tupdate_interrupt();\n}\n\nvoid m68000_device::update_interrupt()'
assert modified['m68000.cpp'].count(anchor) == 1
modified['m68000.cpp'] = modified['m68000.cpp'].replace(anchor, '\tupdate_interrupt();\n\tirq_cutoff_observe("input_applied");\n}\n\nvoid m68000_device::update_interrupt()')
modified['m68000.cpp'] += helper

anchor = '\tvoid update_interrupt();'
assert modified['m68000.h'].count(anchor) == 1
decl = '\tvoid irq_cutoff_observe(const char *event);\n\tu64 m_irq_observe_sequence = 0;\n'
modified['m68000.h'] = modified['m68000.h'].replace(anchor, decl + anchor)

before = '        code.append(["i", "irq_cutoff_observe(\\"cutoff_before\\");"])\n'
after = '        code.append(["i", "irq_cutoff_observe(\\"cutoff_after\\");"])\n'
anchor = '    if ir_to_ird:\n        code.append(["=", R.ird, R.ir])\n        code.append(["i", "if(m_next_state != S_TRACE) m_next_state = m_int_next_state;"])\n'
assert modified['m68000gen.py'].count(anchor) == 1
modified['m68000gen.py'] = modified['m68000gen.py'].replace(anchor, '    if ir_to_ird:\n' + before + '        code.append(["=", R.ird, R.ir])\n        code.append(["i", "if(m_next_state != S_TRACE) m_next_state = m_int_next_state;"])\n' + after)

candidate = HERE / 'candidate' / CPU
candidate.mkdir(parents=True, exist_ok=True)
patch = []
for name, text in modified.items():
    (candidate / name).write_text(text, newline='\n')
    patch += difflib.unified_diff(original[name].splitlines(True), text.splitlines(True), fromfile='a/' + (CPU / name).as_posix(), tofile='b/' + (CPU / name).as_posix())
(HERE / 'observer.patch').write_text(''.join(patch), newline='\n')

job_path = OLD / 'research/irq_sampling_edge_mame61_job.json'
job = json.loads(job_path.read_text())
qualification = OLD / 'research/irq_sampling_edge_mame61_verification.json'
q = json.loads(qualification.read_text())
assert all(v is True for v in q['checks'].values())
exe = OLD / 'tools/mame0289/mame.exe'
assert pin(exe)['sha256'] == job['mame_sha256']
recorder = OLD / 'sim/captures/kyros/irq_sampling_edge_mame61/loaded_recorder.lua'
assert pin(recorder)['sha256'] == job['observer_sha256']

private_tree = 'D:/vibes/fpga/temp/mame289-irq-cutoff-private'
generate = [f'python src/devices/cpu/m68000/m68000gen.py {mode} src/devices/cpu/m68000/m68000.lst src/devices/cpu/m68000/m68000-{mode}.cpp' for mode in ['sdf', 'sif', 'sdp', 'sip']]
assert 'sys.argv[2]' in original['m68000gen.py']
plan = {
    'scope': 'Private source overlay/build plan only. No build, emulator launch, canonical edit, or alteration of the live native4401.',
    'official_reference': {'executable': pin(exe), 'job': pin(job_path), 'verification': pin(qualification), 'recorder': pin(recorder), 'input_sha256': job['input_reference_sha256'], 'actual_terminal_exit0': q['checks']['actual_mame_terminal_exit0'], 'all12_reference_checks_true': len(q['checks']) == 12},
    'source': [pin(MAME / CPU / name) for name in PINS] + [pin(MAME / p) for p in ['src/emu/diexec.cpp', 'src/emu/distate.h', 'makefile', 'scripts/src/cpu.lua', 'src/mame/alpha/alpha68k_n.cpp', 'src/devices/cpu/m68000/m68000.lst']],
    'primary_build_documentation': [{'url': 'https://docs.mamedev.org/initialsetup/compilingmame.html', 'version': '0.289', 'facts': 'C++20; GCC11+/clang13+; native Windows uses MSYS2; driver subset via SUBTARGET/SOURCES/REGENIE=1.'}, {'url': 'https://www.mamedev.org/tools/', 'facts': 'Official Windows MSYS2 toolchain setup.'}],
    'available_environment': {'g++': 'D:/vibes/fpga/toolchains/msys64/ucrt64/bin/g++.exe', 'version': 'GCC16.1.0 Rev5 MSYS2; --version actual success', 'make': 'D:/vibes/fpga/toolchains/msys64/usr/bin/make.exe', 'make_version': 'GNU Make4.4.1; --version actual success', 'python': 'D:/vibes/fpga/toolchains/msys64/ucrt64/bin/python.exe', 'bash': 'D:/vibes/fpga/toolchains/msys64/usr/bin/bash.exe', 'genie_present': True, 'full_dependencies_and_link_not_tested': True},
    'custom_exporter_or_prior_custom_build_receipt': None,
    'overlay': {'state_exports': 'Seven .readonly() state entries; exact sampled state still requires the generator observation, not a frame poll.', 'runtime_hook': 'Before and after exact IR-to-IRD plus m_next_state snapshot, and after execute_set_input update. Logging reads state only; one diagnostic sequence counter.', 'time_coordinates': 'Both CPU local_time and machine time at48MHz, plus total_cycles and icount. These are explicitly distinct; not physical MC68000 nanocode strobes.', 'windows': [[47847465,47851465],[47998000,48002000]], 'window_basis': 'Original pinned native assertions47849465/48000000 +/-2000ticks. Must prove both MAME input_applied assertions and bracketing cutoffs actually present; absence is failure, never timing evidence.', 'regeneration': generate, 'functional_assignments_unchanged': True, 'runtime_equivalence_unproven': True},
    'build_after_copy_and_overlay_review': {'cwd': private_tree, 'shell': 'Explicit MSYS2 UCRT64 Bash environment; MSYSTEM=UCRT64, MINGW_PREFIX=/ucrt64 and PATH=/ucrt64/bin:/usr/bin:$PATH.', 'command': 'make SUBTARGET=kyros_irqcut SOURCES=src/mame/alpha/alpha68k_n.cpp REGENIE=1 -j2', 'generated_source_join': 'cpu.lua2149–2163 compiles checked-in/generated m68000-{sdf,sif,sdp,sip}.cpp; regenerate all four in private tree before make. Do not mistake generator-only edit for compiled observation.', 'blocked_until': 'Separate full source copy/overlay/source manifest and the four generator commands reviewed; ordinary missing build dependencies handled explicitly. No existing executable identity transferred to the custom binary.'},
    'reference61_run_after_build': {'base_command': job['command'], 'required_changes_only': 'Use newly pinned private kyros_irqcut.exe, separate research/capture namespace and cloned recorder output paths; add -log with a separate debug.log. Preserve kyros profile, exact legal first61 inputs, ROM region pins and frame epoch.', 'optional_readonly_tap_fields': ['IRQ_PENDING_STATE','IRQ_NEXT_STATE','IRQ_LEVEL','IRQ_INST_STATE','IRQ_INST_SUBSTATE','IRQ_IRD','IRQ_IRC'], 'qualification': ['Actual new build exit0/exe SHA/full source identity', 'Actual new MAME terminal0 and no Lua failure', 'Exact61 state/PC/SR/input prefix and all reference whole retained images', 'Exact original four CPU-space events and program write/latch ordering, ticks retained', 'Nonvacuous input_applied and cutoff_before/after pairs covering both original IRQs', 'Preserve before/after IR/IRD/pending/next state, local_time and machine time; no shifted fields or offsets', 'Only then compare software cutoff ordering with directly observed native group-one and IR-to-IRD; physical cause remains unproven']},
    'native_direct_receipt': pin(OLD / 'research/irq_dispatch61/compact_acceptance_v2.json'),
    'B16_closed': False, 'physical_cause_proven': False, 'CPU_or_clock_correction_justified': False, 'runtime_mame_cutoff_observed': False,
}
(HERE / 'observer_build_plan.json').write_text(json.dumps(plan, indent=2) + '\n')
(HERE / 'observer_build_plan.md').write_text('''# Private MAME interrupt-cutoff observation

This is a source overlay and build plan, not a completed MAME observation. The official pinned 61-field reference remains authoritative. No existing custom exporter/build receipt is available, and its debugger entries cannot expose pending/next state.

The private overlay exports seven internal values through `.readonly()` debugger entries and logs immediately before/after the existing IR-to-IRD snapshot, plus input application. Sampling only at a Lua memory tap or frame boundary would still miss the execution cutoff. Both CPU local time and machine time are retained because scheduler coordinates are not interchangeable. The two narrow windows must actually contain both assertions and bracketing cutoffs; otherwise the probe fails coverage.

Create a separate complete source copy, apply `observer.patch`, regenerate the four handler variants using the commands in the JSON, and freeze every compiled source before the one minimal-driver build. The local GCC16.1/Make4.4.1 tools exist and answered version commands; dependency/link readiness remains untested. Official build instructions support the driver subset command in the JSON. The original source tree and live RTL4401 remain untouched.

After a successful private build, clone the qualified recorder into a separate capture namespace, preserve its first61 legal inputs/profile/ROMs, and use the newly pinned executable with `-log`. Require the existing state, frame and bus-event parity before interpreting internal records. Retain the actual absolute ticks and source distinctions. Native cutoff evidence is already direct; MAME cutoff runtime and physical PCB fidelity remain unknown. No CPU/clock patch or B16 closure follows from this preparation.

Sources: [MAME0.289 build documentation](https://docs.mamedev.org/initialsetup/compilingmame.html), [official Windows toolchain](https://www.mamedev.org/tools/). Exact local hashes and executable/recorder receipts are in `observer_build_plan.json`.
''')

# Decisive static reversibility check: all original functional source bytes
# after text normalization can be restored by removing the exact observer edits.
restored = dict(modified)
restored['m68000.cpp'] = restored['m68000.cpp'].replace(entries + '\n', '', 1).replace('\tirq_cutoff_observe("input_applied");\n', '', 1).removesuffix(helper)
restored['m68000.h'] = restored['m68000.h'].replace(decl, '', 1)
restored['m68000gen.py'] = restored['m68000gen.py'].replace(before, '', 1).replace(after, '', 1)
checks = {
    'all_three_original_source_pins_match': all(pin(MAME / CPU / n)['sha256'] == h for n, h in PINS.items()),
    'all_original_functional_source_restores_exact': restored == original,
    'seven_readonly_exports': entries.count('.readonly();') == 7,
    'generator_original_snapshot_order_preserved': 'code.append(["=", R.ird, R.ir])\n        code.append(["i", "if(m_next_state != S_TRACE) m_next_state = m_int_next_state;"])' in modified['m68000gen.py'],
    'reference_actual12_checks_true': len(q['checks']) == 12 and all(v is True for v in q['checks'].values()),
    'official_executable_and_recorder_pins_match': pin(exe)['sha256'] == job['mame_sha256'] and pin(recorder)['sha256'] == job['observer_sha256'],
    'no_runtime_or_physical_acceptance_claim': all(plan[k] is False for k in ['B16_closed','physical_cause_proven','CPU_or_clock_correction_justified','runtime_mame_cutoff_observed']),
}
receipt = {'checks': checks, 'static_observer_preparation_pass': all(checks.values()), 'build_or_run_executed': False, 'source_overlays': [pin(candidate / n) for n in PINS], 'limits': 'Static source restoration is not a compiled/runtime equivalence proof. No custom executable produced.'}
(HERE / 'qualification.json').write_text(json.dumps(receipt, indent=2) + '\n')
paths = [HERE / 'prepare_observer.py', HERE / 'observer.patch', HERE / 'observer_build_plan.json', HERE / 'observer_build_plan.md', HERE / 'qualification.json'] + [candidate / n for n in PINS]
manifest = {'files': [{'relative_path': p.relative_to(OLD).as_posix(), 'sha256': pin(p)['sha256'], 'bytes': p.stat().st_size} for p in paths]}
(HERE / 'import_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'checks': checks, 'manifest': pin(HERE / 'import_manifest.json'), 'files': len(paths), 'total_bytes': sum(p.stat().st_size for p in paths)}))
raise SystemExit(0 if all(checks.values()) else 1)
