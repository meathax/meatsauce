from pathlib import Path
import contextlib,json,runpy,time,traceback
O=Path(__file__).resolve().parent
if (O/'audit_exit.json').exists():
    old_exit=json.loads((O/'audit_exit.json').read_text())
    recovery=O/('failed_input_schema_v1' if old_exit['exit_code'] else 'prior_unmasked_latch_and_wrong_elf_key_v2');recovery.mkdir(exist_ok=False)
    for name in ('audit_exit.json','audit_stdout.log','audit_stderr.log','retained_cpu_audio_result.json'):
        if (O/name).exists():(O/name).replace(recovery/name)
started=time.time();exit_code=0
with (O/'audit_stdout.log').open('w',encoding='utf-8') as out,(O/'audit_stderr.log').open('w',encoding='utf-8') as err:
    with contextlib.redirect_stdout(out),contextlib.redirect_stderr(err):
        try:runpy.run_path(str(O/'audit_retained_cpu_audio.py'),run_name='__main__')
        except BaseException:
            traceback.print_exc();exit_code=1
(O/'audit_exit.json').write_text(json.dumps({'exit_code':exit_code,'started':started,'completed':time.time()})+'\n')
print(json.dumps({'exit_code':exit_code,'recovery':str(O)}))
raise SystemExit(exit_code)
