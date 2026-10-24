"""Refresh source lists and OSD/macros without invoking a Quartus build."""
from pathlib import Path
import hashlib,json,subprocess,re
from adapt_timing_constraints import refresh_generated_qsf
from artifact_io import atomic_json,flush_tree

root=Path(__file__).resolve().parents[1]
generated=root/'build/generated'
assert (generated/'arblst.qpf').is_file() and (generated/'arblst.qsf').is_file()
timing_qsf=refresh_generated_qsf(generated/'arblst.qsf')
driver='../../scripts/run_jtframe.sh'
jobs=[(['files','syn','arblst','-t','mister','--local'],None),
      (['files','plain','arblst','-t','mister','--local'],None),
      (['cfgstr','arblst','-t','mister','-o','quartus'],'macros.qsf'),
      (['cfgstr','arblst','-t','mister','-o','cfgstr'],'cfgstr-command.log'),
      (['msg','arblst'],None)]
records=[]
for args,destination in jobs:
    cmd=['wsl.exe','-d','Ubuntu','--cd',str(generated),'--exec','/bin/bash',driver,*args]
    result=subprocess.run(cmd,capture_output=True)
    records.append(dict(argv=cmd,exit_code=result.returncode,
                        stderr=result.stderr.decode('utf-8',errors='replace')))
    log_path=generated/('generator-step-'+str(len(records))+'.log')
    log_path.write_bytes(result.stdout+result.stderr)
    records[-1]['log']=str(log_path)
    if result.returncode:
        atomic_json(generated/'mister-generation-failure.json',dict(commands=records))
        message=result.stdout+result.stderr
        encoding='utf-16-le' if message.count(b'\0')>len(message)//4 else 'utf-8'
        raise RuntimeError(message.decode(encoding,errors='replace')[-4000:])
    if destination:(generated/destination).write_bytes(result.stdout)
    else:(generated/('generate-'+args[0]+'-'+args[1]+'.log')).write_bytes(result.stdout+result.stderr)
assert b'JTARBLST_CRT' in (generated/'macros.qsf').read_bytes()
qip=(generated/'files.qip').read_text()
for name in ('arblst_crt_video.sv','arblst_crt_adjust.sv','arblst_native_crt_adjust.sv'):
    assert name in qip,name
# cfgstr writes the hardware ROM directly; its stdout is intentionally empty.
rom=bytes.fromhex((generated/'cfgstr.hex').read_text())
config=rom.split(b'\0',1)[0]
assert rom==config+b'\0'*(len(rom)-len(config)), 'Unexpected bytes after config terminator'
assert re.search(rb'(?:^|;)V,v[0-9a-f]{7,40}(?:-dirty)?;?$',config), 'Missing complete version trailer'
(generated/'cfgstr.txt').write_bytes(config)
assert b'CRT H-Size' in config and b'O[64]' in config
assert len(config)<=1024,('CONF_STR exceeds declared hps_io STRLEN',len(config))
artifacts=['files.qip','macros.qsf','cfgstr.txt','cfgstr.hex','msg.hex']
hashes={n:hashlib.sha256((generated/n).read_bytes()).hexdigest() for n in artifacts}
flush_tree(generated)
atomic_json(generated/'mister-generation.json',dict(commands=records,
    config_bytes=len(config),artifacts=hashes,timing_qsf=timing_qsf))
print(json.dumps(dict(config_bytes=len(config),artifacts=hashes)))
