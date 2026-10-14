"""Finish the same generated model after the retained collector-scope failure."""
import importlib.util,json,os,re,subprocess,time
from pathlib import Path
S=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('dispatch_prepare',S/'prepare.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def main():
    assert os.name=='posix'
    job=json.loads((S/'job.json').read_text());build=Path(job['build_root'])
    assert json.loads((S/'generation_exit.json').read_text())['exit_code']==0
    assert not (S/'build_running.json').exists() and not (S/'run_job.json').exists()
    header=build/'obj/Valpha68kn_system___024root.h';text=header.read_text()
    host=(build/'system_main.cpp').read_text();initial_host=m.sha(build/'system_main.cpp')
    mapping={}
    for field,scope in m.FIELDS:
        actual_scope='sequencer' if field in ['grp1LatchEn','rInterrupt','rTrace','grp1Nma'] else scope
        matches=re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*'+re.escape('__DOT__'+actual_scope+'__DOT__'+field)+r')\s*;',text)
        assert len(matches)==1,(field,actual_scope,matches)
        member=matches[0];line=next(l.strip() for l in text.splitlines() if member+';' in l)
        mapping[field]={'member':member,'actual_scope':actual_scope,'header_line':line}
    member='alpha68kn_system__DOT__board__DOT__maincpu__DOT__Nanod'
    assert text.count('VlWide<4>/*104:0*/ '+member+';')==1
    # Decode the packed nanocode structure from the actual frozen donor source,
    # independently verifying its total width against the generated model.
    rtl=(build/'fx68k.sv').read_text()
    bodies=re.findall(r'typedef\s+struct\s+packed\s*\{([^}]+)\}\s*(\w+)\s*;',rtl,re.S)
    body=next(b for b,n in bodies if n=='s_nanod')
    clean=re.sub(r'//[^\n]*','',body)
    declarations=re.findall(r'logic\s*(?:\[(\d+)\s*:\s*(\d+)\])?\s*([^;]+);',clean)
    fields=[]
    for hi,lo,names in declarations:
        width=int(hi)-int(lo)+1 if hi else 1
        for name in names.split(','):
            name=name.strip();assert re.fullmatch(r'\w+',name),name;fields.append((name,width))
    assert sum(w for n,w in fields)==105,fields
    offset=0;layout={}
    for name,width in reversed(fields):layout[name]={'lsb':offset,'width':width};offset+=width
    assert layout['Ir2Ird']['width']==1
    names=[x[0] for x in m.FIELDS]
    old_header='tick,frame,address,data_out,attrs_before,attrs_after,'+','.join(n+'_'+side for side in ['before','after'] for n in names)
    new_names=names+['nanod_word0','nanod_word1','nanod_word2','nanod_word3']
    new_header='tick,frame,address,data_out,attrs_before,attrs_after,'+','.join(n+'_'+side for side in ['before','after'] for n in new_names)
    assert host.count(old_header)==1;host=host.replace(old_header,new_header)
    anchor='unsigned(p->@maincpu.Iac@)';assert host.count(anchor)==1
    host=host.replace(anchor,anchor+','+','.join('p->'+member+'['+str(i)+']' for i in range(4)))
    for field,scope in m.FIELDS:host=host.replace('@'+scope+'.'+field+'@',mapping[field]['member'])
    assert all('@'+scope+'.' not in host for field,scope in m.FIELDS)
    (build/'system_main.cpp').write_text(host);(S/'system_main.cpp').write_text(host)
    m.receipt('collector_repair',{'retained_failure':'Original generation0 followed by unmatched direct grp1LatchEn; no make or CPU launch occurred.',
        'original_launcher_log_sha256':m.sha(S/'launcher.log'),'original_job_sha256':m.sha(S/'job.json'),
        'original_prebuild_host_sha256':initial_host,'generated_host_sha256':m.sha(build/'system_main.cpp'),
        'retained_header_sha256':m.sha(header),'field_mapping':mapping,'nanod_layout':layout,
        'nanod_header_member':member,'helper_sha256':m.sha(__file__),
        'hardware_sources_unchanged':all(m.sha(build/name)==job['production_source_pins'][rel] for name,rel in job['copied_source_origins'].items() if name!='system_main.cpp')})
    make=['make','-C','obj','-f','Valpha68kn_system.mk','-j','4']
    with (S/'build.log').open('a') as log:
        p=subprocess.Popen(make,cwd=build,stdout=log,stderr=subprocess.STDOUT)
        m.receipt('build_running',{'actual_worker_pid':os.getpid(),'actual_pid':p.pid,'started':time.time(),'command':make})
        code=p.wait();m.receipt('build_exit',{'actual_pid':p.pid,'exit_code':code,'ended':time.time()})
        assert code==0,'Actual private build failed'
    exe=build/'obj/irq_dispatch61_sim'
    run=[str(exe),str(m.ROOT/'roms/kyros/download.bin'),'61',str(m.CAPTURE),'gameplay','--inputs',str(m.ROOT/'sim/captures/kyros/warm_reset960_refv2/frame_states.csv')]
    with (S/'run.log').open('w') as log:
        p=subprocess.Popen(run,cwd=build,stdout=log,stderr=subprocess.STDOUT)
        m.receipt('run_job',{'actual_pid':p.pid,'actual_worker_pid':os.getpid(),'started':time.time(),'command':run,'actual_ELF_sha256':m.sha(exe)})
        code=p.wait();m.receipt('run_exit',{'actual_pid':p.pid,'exit_code':code,'ended':time.time(),
            'actual_ELF_sha256':m.sha(exe),'run_log_sha256':m.sha(S/'run.log')})
    assert code==0,'Actual real-RTL probe failed'
    p=subprocess.run(['python3',str(S/'verify.py')],capture_output=True,text=True)
    m.receipt('verification_exit',{'actual_exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr,
        'verifier_sha256':m.sha(S/'verify.py'),'ended':time.time()})

if __name__=='__main__':main()
