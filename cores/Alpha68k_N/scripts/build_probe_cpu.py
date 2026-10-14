"""Compile and probe the early real-CPU shell in the explicit Ubuntu environment."""
from pathlib import Path
import json
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]


def main():
    stages=[('build', ['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec','bash','sim/build_cpu.sh']),
            ('probe', ['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec','bash','-c',
                       'cd sim/build && ./alpha68kn_cpu_sim ../../roms/kyros/download.bin 10 ../captures/rtl/kyros_cpu10_strobes'])]
    status=ROOT/'research/rtl_cpu_status.json'
    results=json.loads(status.read_text()) if status.exists() else []
    for name,command in stages:
        log=ROOT/'research'/f'rtl_cpu_{name}_{int(time.time())}.log'
        print('START',name,flush=True)
        start=time.monotonic()
        with log.open('w',encoding='utf-8') as stream:
            child=subprocess.Popen(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
            (ROOT/'research/rtl_cpu_live.json').write_text(json.dumps({'stage':name,'pid':child.pid,'log':log.relative_to(ROOT).as_posix()}))
            try:
                code=child.wait(timeout=600)
            except subprocess.TimeoutExpired:
                child.terminate();child.wait();raise
        result={'stage':name,'exit_code':code,'seconds':round(time.monotonic()-start,3),'log':log.relative_to(ROOT).as_posix()}
        results.append(result)
        status.write_text(json.dumps(results,indent=2)+'\n')
        print('DONE',name,code,result['seconds'],flush=True)
        if code:
            raise RuntimeError(f'{name} failed: {log}')


if __name__=='__main__':main()
