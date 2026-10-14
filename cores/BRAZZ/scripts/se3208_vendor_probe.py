"""Probe the staged primary vendor assembler/disassembler, never game ROM data."""
from pathlib import Path
import csv
import ctypes
import hashlib
import json
import re
import subprocess
ROOT=Path(__file__).resolve().parents[1]
VENDOR=ROOT/'sim/obj_dir/isa_research/vendor_bin'
def run(name,args):
    result=subprocess.run([str(VENDOR/name)]+args,cwd=VENDOR,capture_output=True,text=True,errors='replace')
    if result.returncode:raise RuntimeError(str(args)+': '+result.stderr[-1500:])
    return result.stdout
def disassembly(text):
    rows={}
    for line in text.splitlines():
        m=re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{2}) ([0-9a-f]{2})\s+(\S+)\s*(.*)',line)
        if m:rows[int(m[1],16)]={'opcode':int(m[2],16)|(int(m[3],16)<<8),'mnemonic':m[4],'operands':m[5].strip()}
    return rows
def main():
    ctypes.windll.kernel32.SetErrorMode(3)
    metadata=json.loads((ROOT/'docs/se3208_vendor_tools.json').read_text())
    for name,key in [('se3208-elf-as.exe','assembler_sha256'),('se3208-elf-objdump.exe','objdump_sha256'),('cygwin1.dll','runtime_sha256')]:
        assert hashlib.sha256((VENDOR/name).read_bytes()).hexdigest()==metadata[key]
    cases=[(name,operand,register) for name in ['mvtc','mvfc'] for operand in range(4) for register in range(8)]
    source='.text\n.globl _start\n_start:\n'+''.join(f'{name} {operand},%cr{register}\n' for name,operand,register in cases)
    (VENDOR/'control_matrix.s').write_text(source)
    run('se3208-elf-as.exe',['-o','control_matrix.o','control_matrix.s'])
    text=run('se3208-elf-objdump.exe',['-d','control_matrix.o'])
    (VENDOR/'control_matrix.disasm.txt').write_text(text)
    rows=disassembly(text);assert len(rows)==64
    result=[]
    for i,(name,operand,register) in enumerate(cases):
        row=rows[i*2];assert row['mnemonic']==name
        assert row['opcode']==(0xfc60|(operand<<8)|(8 if name=='mvfc' else 0)|register)
        result.append({'opcode':format(row['opcode'],'04x'),'mnemonic':name,'operand':operand,'register':register})
    with (VENDOR/'control_matrix.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=result[0].keys());writer.writeheader();writer.writerows(result)
    raw='.text\n.globl _start\n_start:\n'+''.join(f'.short 0x{opcode:04x}\n' for opcode in range(0xfc00,0x10000))
    (VENDOR/'control_family.s').write_text(raw)
    run('se3208-elf-as.exe',['-o','control_family.o','control_family.s'])
    family=run('se3208-elf-objdump.exe',['-d','control_family.o'])
    (VENDOR/'control_family.disasm.txt').write_text(family)
    classified=list(disassembly(family).values());assert len(classified)==1024
    counts={}
    for row in classified:counts[row['mnemonic']]=counts.get(row['mnemonic'],0)+1
    with (VENDOR/'control_family.csv').open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['opcode','mnemonic','operands'])
        for row in classified:writer.writerow([format(row['opcode'],'04x'),row['mnemonic'],row['operands']])
    report={'scope':'Primary vendor tool encoding evidence only; control-register side effects unresolved',
        'version':run('se3208-elf-as.exe',['--version']).splitlines()[0],
        'source':metadata['source'],'tools':metadata,
        'canonical_cases':result,'canonical_case_count':len(result),
        'formula':'opcode=0xfc60 | (first_operand<<8) | (read?8:0) | register',
        'first_operand_bits':[8,9],'register_bits':[0,2],'direction_bit':3,
        'family_classification_counts':counts,
        'boot_words':{format(row['opcode'],'04x'):row for row in classified if row['opcode'] in [0xfc65,0xfc6e,0xfc67]},
        'matrix_sha256':hashlib.sha256((VENDOR/'control_matrix.csv').read_bytes()).hexdigest(),
        'family_sha256':hashlib.sha256((VENDOR/'control_family.csv').read_bytes()).hexdigest(),
        'limits':['First operand meaning not inferred merely from encoding','Implicit payload register not proven by these tools','No CR5/CR6/CR7 effects or busy semantics proven','No boot bypass or state injection']}
    (ROOT/'docs/se3208_vendor_encoding.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Vendor canonical controls:',len(result),'family classification:',counts)
    for opcode,row in report['boot_words'].items():print(opcode,row['mnemonic'],row['operands'])
if __name__=='__main__':main()
