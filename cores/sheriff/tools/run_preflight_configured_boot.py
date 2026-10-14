#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run installed Preflight simulation with an explicit HPS gamma configuration.

Uses original platform models and actual current core source. The per-process
boot-script adapter sends UIO_SET_GAMMA=0; no model/state/RTL patch or waiver.
"""
import argparse
import json
import os
from pathlib import Path
import sys

# The installed reporter uses the interpreter's default text encoding.
# Windows cp1252 cannot write its checkmarks; establish UTF-8 before any run.
if not sys.flags.utf8_mode:
    os.execv(sys.executable, [sys.executable, '-X', 'utf8', *sys.argv])

parser = argparse.ArgumentParser()
parser.add_argument('--preflight-root', type=Path, required=True)
parser.add_argument('--roms', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
assert output.is_relative_to(root)
output.mkdir(parents=True, exist_ok=False)
sys.path.insert(0, str(args.preflight_root.resolve() / 'src'))
from preflight import hps, util
util.setup_env()
original_boot = hps.boot_script

def configured_boot(*args, **kwargs):
    script = original_boot(*args, **kwargs)
    assert script.count('mark boot_done') == 1
    return script.replace('mark boot_done',
                          'uio 0x32 0x0   # explicit disabled HPS gamma configuration\nmark boot_done')

hps.boot_script = configured_boot
from preflight.cli import main
cli = ['--repo', str(root), '--roms', str(args.roms.resolve()), '--foreground',
       '--seeds', '2', '--frames', '120', '--no-diagnose', '--force']
(output / 'receipt.json').write_text(json.dumps({
    'scope': 'Current-source installed full-wrapper simulation with configured HPS gamma',
    'cli_arguments': cli, 'firmware_command': 'UIO_SET_GAMMA (0x32), value 0',
    'rtl_changed': False, 'models_changed': False, 'state_forced': False,
    'finding_waived': False, 'quartus_requested': False,
    'protocol_reference': 'https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.h',
    'gamma_sequence_reference': 'https://github.com/MiSTer-devel/Main_MiSTer/blob/master/video.cpp',
}, indent=2) + '\n')
code = main(cli)
(output / 'exit_code.txt').write_text(str(code) + '\n')
raise SystemExit(code)
