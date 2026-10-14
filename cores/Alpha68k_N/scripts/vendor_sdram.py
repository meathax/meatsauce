"""Import the pinned JTFRAME SDRAM closure without changing donor bytes."""
from pathlib import Path
import hashlib, json, subprocess
ROOT = Path(__file__).resolve().parents[1]
REVISION = '548b87b32a1b528a16cb41f689accb179e85d1a8'
def main():
    donor = ROOT/'donors/jtcores'
    revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=donor,text=True).strip()
    if revision != REVISION: raise RuntimeError('JTFRAME revision changed: '+revision)
    target = ROOT/'rtl/vendor/jtframe_sdram'
    target.mkdir(parents=True,exist_ok=True)
    records = []
    for name in ['jtframe_sdram64.v','jtframe_sdram64_bank.v','jtframe_sdram64_init.v',
                 'jtframe_sdram64_latch.v','jtframe_sdram64_rfsh.v','LICENSE']:
        relative = 'LICENSE' if name == 'LICENSE' else 'modules/jtframe/hdl/sdram/'+name
        data = (donor/relative).read_bytes()
        (target/name).write_bytes(data)
        records.append({'path':(target/name).relative_to(ROOT).as_posix(),
            'source_path':relative,'revision':REVISION,
            'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
    (target/'provenance.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps({'revision':REVISION,'files':len(records)}))
if __name__ == '__main__': main()
