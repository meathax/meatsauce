from pathlib import Path
import re,json,hashlib
r=Path(__file__).resolve().parents[1]
s=(r/'sys/arcade_video.v').read_text()
first='reg [11:0] hcnt = 0, vcnt = 0;'
second='reg [13:0] hcnt = 0;'
assert s.count(first)==s.count(second)==1
for decl,names,defs in [
 (first,{'hcnt':'capture_hcnt','vcnt':'capture_vcnt'},'reg [11:0] capture_hcnt = 0, capture_vcnt = 0;'),
 (second,{'hcnt':'write_hcnt'},'reg [13:0] write_hcnt = 0;')]:
 start=s.rfind('always @(posedge CLK_VIDEO)',0,s.index(decl))
 end=s.find('always @(posedge CLK_VIDEO)',s.index(decl)+len(decl))
 if end<0:end=s.index('endmodule',s.index(decl))
 chunk=s[start:end].replace(decl,'')
 for old,new in names.items():chunk=re.sub(r'\b'+old+r'\b',new,chunk)
 s=s[:start]+defs+'\n'+chunk+s[end:]
out=r/'sim/results/display-platform.sv';out.write_text(s)
print(json.dumps({'simulation_copy':str(out.relative_to(r)),'original_sha256':hashlib.sha256((r/'sys/arcade_video.v').read_bytes()).hexdigest(),'copy_sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'change':'Hoist three initialized procedural static counters, retaining widths, zero initializers and all expressions. Production sys unchanged.'}))
