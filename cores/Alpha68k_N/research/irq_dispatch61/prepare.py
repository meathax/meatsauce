"""One private current-image real-CPU recognition-boundary probe. Run in Ubuntu."""
import hashlib,json,os,re,shutil,subprocess,tempfile,time
from pathlib import Path

ROOT=Path('/mnt/d/Arcade/AI/aCORES/Alpha68k N')
STAGE=ROOT/'research/irq_dispatch61'
CAPTURE=ROOT/'sim/captures/rtl/irq_dispatch61'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def receipt(name,obj):
    with (STAGE/(name+'.json')).open('x') as f:json.dump(obj,f,indent=2);f.write('\n')

FIELDS=[('irq1','board'),('irq2','board'),('level','board'),('cpu_phase','board'),
    ('Clks','maincpu'),('tState','maincpu'),('enT1','maincpu'),('enT3','maincpu'),('enT4','maincpu'),
    ('rIpl','maincpu'),('iIpl','maincpu'),('intPend','maincpu'),('inl','maincpu'),('updIll','maincpu'),
    ('microLatch','maincpu'),('microAddr','maincpu'),('nma','maincpu'),('grp1LatchEn','maincpu'),
    ('rInterrupt','maincpu'),('rTrace','maincpu'),('grp1Nma','maincpu'),('tvn','maincpu'),
    ('Ir','maincpu'),('Ird','maincpu'),('Irc','maincpu'),('pswI','maincpu'),
    ('PcH','excUnit'),('PcL','excUnit'),('Iac','maincpu')]

def main():
    assert os.name=='posix' and not CAPTURE.exists(),'Explicit Ubuntu and fresh namespace required'
    baseline=ROOT/'research/kyros_merged_lifecycle_v2_compiled_exit.json'
    frozen=json.loads(baseline.read_text());assert frozen['exit_code']==0
    oldbuild=Path(frozen['build_root'])
    pins=frozen['production_source_pins']
    build=Path(tempfile.mkdtemp(prefix='alpha68kn-dispatch61.',dir='/mnt/d/vibes/fpga/temp'))
    origins={}
    for rel,digest in pins.items():
        source=oldbuild/Path(rel).name
        assert source.is_file() and sha(source)==digest,(rel,str(source))
        assert source.name not in origins,'Colliding frozen source basenames'
        shutil.copy2(source,build/source.name);origins[source.name]=rel
    host=(build/'system_main.cpp').read_text()
    assert 'Valpha68kn_system___024root.h' in host
    assert 'work_hi' in host and 'work_lo' in host and 'strip_hi' in host and 'strip_lo' in host
    # Read-only public metadata, with no source RTL edits or hierarchical writes.
    config='`verilator_config\n'+''.join('public_flat_rd -module "'+{'board':'alpha68kn_board','maincpu':'fx68k','excUnit':'excUnit'}[scope]+'" -var "'+field+'"\n' for field,scope in FIELDS)
    (build/'observer.vlt').write_text(config);(STAGE/'observer.vlt').write_text(config)
    stream='    std::ofstream applied_inputs(output/"applied_inputs.csv");'
    assert host.count(stream)==1
    names=[x[0] for x in FIELDS]
    header='tick,frame,address,data_out,attrs_before,attrs_after,'+','.join(n+'_'+side for side in ['before','after'] for n in names)
    insert='    std::ofstream dispatch_trace(output/"dispatch.csv");\n    dispatch_trace<<"'+header+'\\n";\n'
    host=host.replace(stream,insert+stream)
    top='    Valpha68kn_system top;\n';assert host.count(top)==1
    observe='    auto observe_dispatch=[&]() { auto *p=top.rootp; return std::vector<uint32_t>{'+','.join('unsigned(p->@'+scope+'.'+field+'@)' for field,scope in FIELDS)+'}; };\n'
    host=host.replace(top,top+observe)
    anchor='        tick();\n        if(top.audio_sample_ce) {';assert host.count(anchor)==1
    replacement='''        bool dispatch_roi=frame>=58 && frame<=60;
        std::vector<uint32_t> dispatch_before;
        if(dispatch_roi) dispatch_before=observe_dispatch();
        tick();
        if(dispatch_roi) {
            auto dispatch_after=observe_dispatch();
            // Continuous intervals surround the two original assertions and writes,
            // plus the next field's assertions; all group-one/IR/IRQ transitions remain.
            auto dt=ticks-started;
            bool focused=(dt>=47848000 && dt<=47854000) ||
                         (dt>=47923000 && dt<=47928000) ||
                         (dt>=47998000 && dt<=48006000) ||
                         (dt>=48659000 && dt<=48669000) ||
                         (dt>=48798000 && dt<=48808000);
            bool boundary_event=dispatch_before[7] && dispatch_before[17];
            bool changed=dispatch_before[0]!=dispatch_after[0] || dispatch_before[1]!=dispatch_after[1] ||
                         dispatch_before[18]!=dispatch_after[18] || dispatch_before[22]!=dispatch_after[22] ||
                         dispatch_before[23]!=dispatch_after[23];
            if(focused || boundary_event || changed || ((attrs|top.debug_main_attrs)&8)) {
                dispatch_trace<<dt<<','<<frame<<','<<address<<','<<dataout<<','<<unsigned(attrs)<<','<<unsigned(top.debug_main_attrs);
                for(auto v:dispatch_before) dispatch_trace<<','<<v;
                for(auto v:dispatch_after) dispatch_trace<<','<<v;
                dispatch_trace<<'\\n';
            }
        }
        if(top.audio_sample_ce) {'''
    host=host.replace(anchor,replacement)
    (build/'system_main.cpp').write_text(host)
    command=list(frozen['build_command']);command.remove('--build')
    command[command.index('-o')+1]='irq_dispatch61_sim'
    command[command.index('alpha68kn_board.sv'):command.index('alpha68kn_board.sv')]=['observer.vlt']
    command=[str(build/'system_main.cpp') if x.endswith('/system_main.cpp') else x for x in command]
    assert subprocess.check_output([command[0],'--version'],text=True).strip()==frozen['verilator_version']
    input_path=ROOT/'sim/captures/kyros/warm_reset960_refv2/frame_states.csv'
    prior=json.loads((ROOT/'research/irq_ipl_recognition61_job.json').read_text())
    rom=ROOT/'roms/kyros/download.bin'
    assert sha(input_path)==prior['input_trace_sha256'] and sha(rom)==prior['rom_sha256']
    CAPTURE.mkdir(parents=True)
    receipt('job',{'actual_worker_pid':os.getpid(),'started':time.time(),'frames':61,
        'hardware_commit':frozen['canonical_commit'],'compiled_baseline_pin':sha(baseline),
        'production_source_pins':pins,'copied_source_origins':origins,'build_root':str(build),
        'input_sha256':sha(input_path),'ROM_sha256':sha(rom),'prior_IPL_job_pin':sha(ROOT/'research/irq_ipl_recognition61_job.json'),
        'config_sha256':sha(build/'observer.vlt'),'script_sha256':sha(__file__),
        'generation_command':command,'verilator_version':frozen['verilator_version'],
        'scope':'Frozen actual merged4401 hardware source image plus private read-only group-one/sequence observer. No clock/state/RTL modification or MAME dispatch equivalence claim.'})
    with (STAGE/'build.log').open('w') as log:
        gen=subprocess.Popen(command,cwd=build,stdout=log,stderr=subprocess.STDOUT)
        receipt('generation_running',{'actual_pid':gen.pid,'started':time.time()})
        code=gen.wait();receipt('generation_exit',{'actual_pid':gen.pid,'exit_code':code,'ended':time.time()})
        assert code==0,'Actual Verilator generation failed'
        text=(build/'obj/Valpha68kn_system___024root.h').read_text();mapping={}
        for field,scope in FIELDS:
            matches=re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*'+re.escape('__DOT__'+scope+'__DOT__'+field)+r')\s*;',text)
            assert len(matches)==1,(field,matches)
            member=matches[0];line=next(l.strip() for l in text.splitlines() if member+';' in l)
            mapping[field]={'member':member,'header_line':line}
            host=host.replace('@'+scope+'.'+field+'@',member)
        assert '@maincpu.' not in host and '@board.' not in host and '@excUnit.' not in host
        (build/'system_main.cpp').write_text(host);(STAGE/'system_main.cpp').write_text(host)
        receipt('source',{'generated_host_sha256':sha(build/'system_main.cpp'),
            'retained_header_sha256':sha(build/'obj/Valpha68kn_system___024root.h'),'field_mapping':mapping,
            'production_copied_pins_unchanged':all(sha(build/name)==pins[rel] for name,rel in origins.items() if name!='system_main.cpp')})
        make=['make','-C','obj','-f','Valpha68kn_system.mk','-j','4']
        proc=subprocess.Popen(make,cwd=build,stdout=log,stderr=subprocess.STDOUT)
        receipt('build_running',{'actual_pid':proc.pid,'started':time.time(),'command':make})
        code=proc.wait();receipt('build_exit',{'actual_pid':proc.pid,'exit_code':code,'ended':time.time()})
        assert code==0,'Actual private build failed'
    exe=build/'obj/irq_dispatch61_sim'
    run=[str(exe),str(rom),'61',str(CAPTURE),'gameplay','--inputs',str(input_path)]
    with (STAGE/'run.log').open('w') as log:
        proc=subprocess.Popen(run,cwd=build,stdout=log,stderr=subprocess.STDOUT)
        receipt('run_job',{'actual_pid':proc.pid,'started':time.time(),'command':run,'actual_ELF_sha256':sha(exe)})
        code=proc.wait();receipt('run_exit',{'actual_pid':proc.pid,'exit_code':code,'ended':time.time(),
            'actual_ELF_sha256':sha(exe),'run_log_sha256':sha(STAGE/'run.log')})
    assert code==0,'Actual private real-RTL observation failed'

if __name__=='__main__':main()
