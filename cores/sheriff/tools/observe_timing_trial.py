# SPDX-License-Identifier: GPL-2.0-or-later
"""Observe a retained placement trial without starting or changing Quartus."""
import argparse, datetime, hashlib, json
from pathlib import Path

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            digest.update(block)
    return digest.hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('trial', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
manifest_path = args.trial/'source.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
source = args.trial/'source'
mismatches = [name for name, expected in manifest['source_sha256'].items()
              if not (source/name).is_file() or sha(source/name) != expected]
fit_receipt = args.trial/'fit.json'
receipt = json.loads(fit_receipt.read_text(encoding='utf-8-sig')) if fit_receipt.exists() else None
stdout = args.trial/'fit.stdout.log'
qsf = (source/'Nintendo8080.qsf').read_text(encoding='utf-8-sig')
result = dict(scope='Retained 66f53ed9 SEED2 placement-only trial; not current-source qualification',
    observed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    trial=str(args.trial.resolve()), manifest_sha256=sha(manifest_path),
    source_identity=manifest['source_identity'], source_inputs_verified=len(manifest['source_sha256']),
    source_mismatches=mismatches, source_qualified=not mismatches,
    fit_complete=receipt is not None, fit_receipt=receipt,
    fit_actual_exit=receipt.get('exit_code') if receipt else None,
    fit_receipt_sha256=sha(fit_receipt) if receipt else None,
    fit_stdout_sha256=sha(stdout) if stdout.exists() else None,
    fit_stdout_bytes=stdout.stat().st_size if stdout.exists() else None,
    fit_stdout_tail=stdout.read_text(encoding='utf-8',errors='replace').splitlines()[-8:] if stdout.exists() else [],
    rbf_generation_off='GENERATE_RBF_FILE OFF' in qsf,
    baseline_setup_minimum_ns=-0.008,new_compiler_runs=0,new_native_runs=0,assembly_requested=False,
    next_step='Await existing fitter receipt, then all-corner STA on stable trial database with hardened gate')
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({key:result[key] for key in ('source_identity','source_inputs_verified','source_mismatches','fit_complete','fit_actual_exit','fit_stdout_bytes','rbf_generation_off','new_compiler_runs')}))
raise SystemExit(1 if mismatches or not result['rbf_generation_off'] else 0)
