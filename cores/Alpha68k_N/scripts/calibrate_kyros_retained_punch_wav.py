"""Finite existing-PCM comparison and raw excerpts; no simulation or waveform-phase requirement."""
from pathlib import Path
import csv,json,hashlib,wave,array,math,cmath
R=Path(__file__).resolve().parents[1]
D=R/"sim/captures/diagnostics/kyros_retained_punch_wav";D.mkdir(exist_ok=False)
A=R/"sim/captures/rtl/kyros_punch_release1081";B=R/"sim/captures/kyros/punch_release1081_components"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def rows(p):
 with p.open(newline="") as f:return list(csv.DictReader(f))
def pcm(p):
 with wave.open(str(p),"rb") as w:
  assert w.getframerate()==48000 and w.getnchannels()==1 and w.getsampwidth()==2
  a=array.array("h",w.readframes(w.getnframes()))
 return a
def stats(a):
 mean=sum(a)/len(a);return {"samples":len(a),"mean":mean,"AC_RMS":math.sqrt(sum((x-mean)**2 for x in a)/len(a)),"minimum":min(a),"maximum":max(a),"saturation_samples":sum(x in [-32768,32767] for x in a)}
def fft(a):
 if len(a)==1:return [complex(a[0])]
 e=fft(a[::2]);o=fft(a[1::2]);n=len(a);t=[cmath.exp(-2j*math.pi*k/n)*o[k] for k in range(n//2)]
 return [e[k]+t[k] for k in range(n//2)]+[e[k]-t[k] for k in range(n//2)]
def spectrum(a):
 mean=sum(a)/len(a);x=[(v-mean)*(.5-.5*math.cos(2*math.pi*i/(len(a)-1))) for i,v in enumerate(a)]
 f=fft(x);p=[abs(v)**2 for v in f[:len(a)//2+1]]
 dominant=max(range(1,len(p)),key=p.__getitem__)
 return {"FFT_samples":len(a),"bin_resolution_Hz":48000/len(a),"dominant_frequency_Hz":dominant*48000/len(a),
 "top_bins":[{"Hz":i*48000/len(a),"power":p[i]} for i in sorted(range(1,len(p)),key=p.__getitem__,reverse=True)[:8]]}
na=pcm(A/"audio.wav");ma=pcm(B/"audio.wav")
n=rows(A/"audio_events.csv");m=rows(B/"all_sound_io.csv")
nn=[(int(x["frame"]),int(x["address"]),int(x["data"])) for x in n if x["kind"]=="write" and 712<=int(x["frame"])<=736]
mm=[(int(x["frame"]),int(x["address"]),int(x["data"])) for x in m if 712<=int(x["frame"])<=736]
# Frame period is 384*264 pixels at6MHz, source-defined811008masterticks.
period=811008/48000000
short_start=712*period;short_end=736*period
clips=[]
for label,a in [("native",na),("mame",ma)]:
 lo=round(short_start*48000);hi=round(short_end*48000);b=a[lo:hi]
 p=D/(label+"_punch_712_736.wav")
 with wave.open(str(p),"wb") as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b.tobytes())
 clips.append({"path":str(p),"sha256":sha(p),"start_seconds":lo/48000,"end_seconds":hi/48000,"stats":stats(b),"no_normalization_or_filter":True})
# Interior723 interval: selected identical register command state; guard against field callback boundary.
start=12.225;count=512
ns=na[round(start*48000):round(start*48000)+count];ms=ma[round(start*48000):round(start*48000)+count]
nstat=stats(ns);mstat=stats(ms);nf=spectrum(ns);mf=spectrum(ms)
baseline_native=stats(na[480:960]);baseline_mame=stats(ma[480:960])
comp=rows(B/"sound_components.csv")
baseline={x["component"]:x for x in comp if x["update"]=="0" and x["component"] in ["fm","ym_ssg","ay1","ay2","dac"]}
means={k:float(x["sum"])/int(x["samples"]) for k,x in baseline.items()}
expected_native_dc=(-241591910-483183821-128*8388608)>>16
# Actual source-exact mixer DC transfer is checked with retained hardware WAV, not copied expected WAV.
checks={"shared_accepted_punch_commands_all_exact":nn==mm and len(nn)>0,
"native_baseline_pcm_matches_nominal_Q16_route_sum":baseline_native["minimum"]==baseline_native["maximum"]==expected_native_dc,
"retained_MAME_AY2_to_AY1_DC_route_ratio_two":abs(means["ay2"]/means["ay1"]-2)<1e-10,
"both_short_WAVs_saturation_zero":all(x["stats"]["saturation_samples"]==0 for x in clips),
"interior_noise_mixed_PCM_dynamic":nstat["AC_RMS"]>0 and mstat["AC_RMS"]>0,
"interior_dominant_frequency_within_one_resolution_bin":abs(nf["dominant_frequency_Hz"]-mf["dominant_frequency_Hz"])<=nf["bin_resolution_Hz"]}
reg=[0]*16;selected=0;states=[]
for x in n:
 if x["kind"]!="write":continue
 addr=int(x["address"]);data=int(x["data"])
 if addr==145:selected=data&15
 if addr==144:
  reg[selected]=data
  if 714<=int(x["frame"])<=734 and selected in [6,7,9]:states.append({"frame":int(x["frame"]),"tick":int(x["tick"]),"register":selected,"data":data,"noise_period":reg[6]&31,"mixer":reg[7],"Bvolume":reg[9]})
out={"scope":"Finite existing native/MAME shared punch command interval; measured raw WAV/DC/clipping/AC and dominant-bin comparison. No phase-identical PCM or individual FM/PSG tone-frequency/complete route balance claim.",
"checks":checks,"all_finite_checks_true":all(x is True for x in checks.values()),"clips":clips,
"interior_window":{"start_seconds":start,"samples":count,"native":nstat,"MAME":mstat,"native_spectrum":nf,"MAME_spectrum":mf,
"AC_RMS_relative_difference":(nstat["AC_RMS"]-mstat["AC_RMS"])/mstat["AC_RMS"],
"limits":"10.67ms mixed noise/FM window. Dominant mixed bin is not the AY LFSR update frequency or an isolated chip pitch measurement. RMS difference is measured without an invented pass tolerance."},
"baseline":{"native":baseline_native,"MAME":baseline_mame,"MAME_device_postroute_means":means,"native_Q16_expected_DC":expected_native_dc},
"actual_AY2_register_transitions":states,
"source_and_data_pins":[{"path":str(p),"sha256":sha(p)} for p in [A/"audio.wav",B/"audio.wav",A/"audio_events.csv",B/"all_sound_io.csv",B/"sound_components.csv",Path(__file__)]],
"smallest_remaining_gap":"Retained MAME components are per-update aggregate means/squared sums, not per-sample per-chip waveforms. Native original punch capture has only final mixed PCM. Separate FM/SSG/AY frequency and individual route amplitudes remain unmeasured by this finite comparison. Reuse existing isolated production-chip frequency/mixer receipts if source-valid; otherwise only an isolated accepted-command chip output capture is needed, not another CPU playthrough.",
"fullP5pass":False,"fullB03_B06pass":False}
p=R/"research/kyros_retained_punch_wav_calibration.json";p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"checks":checks,"baseline":out["baseline"],"interior":out["interior_window"],"clip_sha":[x["sha256"] for x in clips],"receipt_sha256":sha(p)}))
raise SystemExit(0 if out["all_finite_checks_true"] else 1)
