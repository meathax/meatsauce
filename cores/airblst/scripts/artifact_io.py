"""Durable, atomic receipts for owned generated simulation artifacts."""
from pathlib import Path
import json,os,uuid

def atomic_json(path,value):
    path=Path(path)
    payload=json.dumps(value,indent=2,allow_nan=False)+'\n'
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    with temporary.open('w',encoding='utf-8',newline='\n') as stream:
        stream.write(payload);stream.flush();os.fsync(stream.fileno())
    assert json.loads(temporary.read_text(encoding='utf-8'))==value
    os.replace(temporary,path)

def flush_tree(path):
    root=Path(path).resolve()
    for p in root.rglob('*'):
        assert p.resolve().is_relative_to(root),str(p)
        assert not p.is_symlink(),str(p)
        if p.is_file():
            with p.open('r+b') as stream:os.fsync(stream.fileno())
