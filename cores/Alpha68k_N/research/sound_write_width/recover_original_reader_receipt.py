"""Restore original observation only with its exact immutable SHA; preserve later observation elsewhere."""
from pathlib import Path
import hashlib,json
base=Path(__file__).resolve().parent
expected='20dd4500fbc88d038862c542356cb7dd2b18aea41243bca23307a8a8c10a4996'
command='"D:\\vibes\\fpga\\toolchains\\msys64\\ucrt64\\bin\\python.exe" "D:\\Arcade\\AI\\aCORES\\Alpha68k N\\research\\sound_write_width\\inspect_owned_jobs.py"'
stdout=json.dumps({'ProcessId':33456,'ParentProcessId':33172,'CommandLine':command},separators=(',',':'))+'\n'
text=json.dumps({'exit':0,'stdout':stdout,'stderr':''},indent=2)+'\n'
candidates=[text.encode(),text.replace('\n','\r\n').encode()]
rows=[{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for data in candidates]
matches=[data for data in candidates if hashlib.sha256(data).hexdigest()==expected]
if matches: (base/'owned_jobs_observation.json').write_bytes(matches[0])
result={'restored_exact_original':bool(matches),'expected':expected,'candidates':rows,'reason':'Windows Path.write_text newline conversion; restoration only if exact original tool-output reconstruction hash matches.'}
(base/'case2_fit_sta/reader_receipt_exact_recovery.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
