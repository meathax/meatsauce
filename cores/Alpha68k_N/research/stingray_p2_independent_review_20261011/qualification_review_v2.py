from pathlib import Path

# Preserve the original immutable review and its startup-inclusive failure.
# Command handshake transitions are specifically C8->D8 and D8->C8.
source=(Path(__file__).parent/'qualification_review_v1.py').read_text()
source=source.replace('qualification_review_v1','qualification_review_v2')
source=source.replace("not row['control_before']&16 and row['control_after']&16", "row['control_before']==200 and row['control_after']==216")
source=source.replace("row['control_before']&16 and not row['control_after']&16", "row['control_before']==216 and row['control_after']==200")
exec(compile(source,str(Path(__file__).resolve()),'exec'),{'__file__':str(Path(__file__).resolve()),'__name__':'__main__'})
