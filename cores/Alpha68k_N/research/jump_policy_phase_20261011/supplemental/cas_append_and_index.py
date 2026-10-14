"""Root-review recipe. Default is a read-only CAS preview; --apply writes globally."""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,sys,tempfile
S=Path(__file__).resolve().parent
TARGET=Path('C:/Users/meath/.codex/lessons.md')
INDEX=Path('C:/Users/meath/codex-tools/maintenance/lessons_index.py')
BACKUPS=Path('C:/Users/meath/codex-tools/backups/lessons')
TITLE=b'## 2026-10-11 - Trace CPU bus direction before accepting observer data'
def sha(raw):return hashlib.sha256(raw).hexdigest()
def proposed(base,entry,expected):
    assert sha(base)==expected,'CAS mismatch: refresh and review; never overwrite another lesson update'
    assert entry.startswith(TITLE) and TITLE not in base,'Duplicate or unexpected lesson'
    return base+(b'\n\n' if not base.endswith(b'\n') else b'\n')+entry
def self_test():
    base=b'# local fixture\r\n';entry=TITLE+b'\nContext: fixture.\n';out=proposed(base,entry,sha(base))
    assert out.startswith(base) and out.count(TITLE)==1
    for raw,h in [(base,'0'*64),(out,sha(out))]:
        try:proposed(raw,entry,h)
        except AssertionError:pass
        else:raise AssertionError('CAS/duplicate refusal missing')
    return {'local_tests':3,'global_writes':False}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--apply',action='store_true');ap.add_argument('--self-test',action='store_true');args=ap.parse_args()
    if args.self_test:print(json.dumps(self_test()));return 0
    receipt=json.loads((S/'preparation.json').read_bytes());entry=(S/'entry.md').read_bytes()
    assert sha(entry)==receipt['entry_sha256'];base=TARGET.read_bytes();out=proposed(base,entry,receipt['expected_global_sha256'])
    if not args.apply:
        print(json.dumps({'mode':'preview','expected_global_sha256':sha(base),'proposed_global_sha256':sha(out),'global_writes':False}));return 0
    # Windows range lock and in-handle CAS retain every prior byte; no replacement
    # of the corpus, no copy of it into project evidence, and no silent rollback.
    import msvcrt
    with TARGET.open('r+b') as f:
        span=len(out)+1;f.seek(0);msvcrt.locking(f.fileno(),msvcrt.LK_NBLCK,span)
        try:
            locked=f.read();assert locked==base and sha(locked)==receipt['expected_global_sha256'],'CAS changed before append'
            BACKUPS.mkdir(parents=True,exist_ok=True)
            backup=BACKUPS/('lessons-before-cpu-bus-direction-'+sha(base)+'.md')
            if backup.exists():assert backup.read_bytes()==base
            else:
                with backup.open('xb') as b:b.write(base)
            f.seek(len(base));f.write(out[len(base):]);f.flush();os.fsync(f.fileno())
        finally:f.seek(0);msvcrt.locking(f.fileno(),msvcrt.LK_UNLCK,span)
    assert TARGET.read_bytes()==out
    index=subprocess.run([sys.executable,'-X','utf8',str(INDEX),'index'],capture_output=True,text=True,encoding='utf-8')
    result={'global_append_completed':True,'before_sha256':sha(base),'after_sha256':sha(out),'backup':str(backup),'index_actual_exit':index.returncode,'index_stdout':index.stdout,'index_stderr':index.stderr}
    (S/'root_apply_receipt.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if not k.startswith('index_std')}));return index.returncode
if __name__=='__main__':raise SystemExit(main())

