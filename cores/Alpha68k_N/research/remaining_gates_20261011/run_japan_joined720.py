"""One authorized frozen-ELF Japan replay with durable native and verifier exits."""
from pathlib import Path
import csv, hashlib, json, os, re, subprocess, sys, time

O = Path(__file__).resolve().parent
R = O.parents[1]
P = O / "japan_joined720_preparation.json"
N = O / "japan_joined720"
T = N / "capture"
EXPECTED_PREPARATION = "f5d2a3a5ef96c9bd6112868f6dccc1d24c33ba6426a1e504355acd93eee7831d"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def write(name, data):
    p = N / name
    assert not p.exists(), str(p)
    p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
def rows(p):
    with p.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))
def check_pins():
    assert sha(P) == EXPECTED_PREPARATION
    p = js(P)
    pins = [p[k] for k in ("existing_source_closure", "existing_build",
            "existing_terminal", "existing_protocol_qualification", "ELF", "ROM", "inputs", "old_Japan720")]
    pins += p["reference_artifacts"]
    assert all(sha(Path(x["path"])) == x["sha256"] for x in pins)
    sources = js(Path(p["existing_source_closure"]["path"]))["source_files"]
    assert len(sources) == 75
    assert all(sha(Path(x["path"])) == x["combined_sha256"] for x in sources)
    return p
def verify():
    p = check_pins()
    terminal = js(N / "run_exit.json")
    old = R / "sim/captures/rtl/kyrosj_current720_curvefixed_drive"
    reference = R / "sim/captures/kyrosj/kyrosj_sound_fulltap720"
    fields = rows(T / "frames.csv")
    checks = {"actual_native_exit0": terminal["exit_code"] == 0,
              "frozen75_sources_ELF_ROM_input_reference_pins": True,
              "actual_profile1_ROM": Path(p["ROM"]["path"]).read_bytes()[5] == 1,
              "720_contiguous_native_fields": len(fields) == 720 and [int(x["frame"]) for x in fields] == list(range(720)),
              "all_pixels57344_no_duplicates_deadlines_overflows_unmapped": all(int(x["pixels"]) == 57344 and all(int(x[k]) == 0 for k in ("duplicates", "deadline_misses", "row_overflows", "unmapped")) for x in fields)}
    expected = {int(x["frame"]): x for x in rows(Path(p["inputs"]["path"]))}
    applied = rows(T / "applied_inputs.csv")
    pairs = (("controls", "in0"), ("dips", "in1"), ("coins_n", "in2"))
    differences = [x for x in applied if int(x["frame"]) in expected and any(int(x[a]) != int(expected[int(x["frame"])][b]) for a, b in pairs)]
    checks["all_actual_ports_at_original_snapshot_boundary"] = len(applied) >= 720 and not differences and applied == rows(old / "applied_inputs.csv")
    arrays = []
    for field in (0, 30, 90, 240, 360, 600):
        for suffix in ("rgb", "work.bin", "sprites.bin"):
            a = T / f"frame_{field:06d}.{suffix}"
            b = R / "sim/captures/kyrosj/gameplay" / a.name
            aa, bb = a.read_bytes(), b.read_bytes()
            different = sum(x != y for x, y in zip(aa, bb)) + abs(len(aa) - len(bb))
            arrays.append({"field": field, "suffix": suffix, "native_sha256": sha(a), "reference_sha256": sha(b), "different_bytes": different, "native_bytes": len(aa), "reference_bytes": len(bb)})
    checks["all18_full_RGB_work_strip_arrays_exact"] = all(x["different_bytes"] == 0 for x in arrays) and all(x["native_bytes"] == 57344 * 3 for x in arrays if x["suffix"] == "rgb")
    events = rows(reference / "events.csv")
    audio = rows(T / "audio_events.csv")
    key = lambda x: (int(x["address"]), int(x["data"]))
    sound_ref = [key(x) for x in events if x["area"] == "sound_io"]
    sound_native = [key(x) for x in audio if x["kind"] == "write"]
    checks["global_ordered_fulltap_sound_chip_data_exact"] = sound_ref == sound_native
    checks["fulltap_sound_chip_original_field_labels_exact"] = [int(x["frame"]) for x in events if x["area"] == "sound_io"] == [int(x["frame"]) for x in audio if x["kind"] == "write"]
    dac_ref = [int(x["data"]) for x in events if x["area"] == "sound_memory" and int(x["address"]) == 0xe004]
    dac_native = [int(x["data"]) for x in audio if x["kind"] == "dac"]
    checks["fulltap_DAC_ordered_data_exact"] = dac_ref == dac_native
    native_latches = []
    with (T / "epoch_events.csv").open(newline="") as f:
        for x in csv.DictReader(f):
            if int(x["address"]) == 0xe0000 and x["iack"] == "0" and x["rw"] == "0" and x["uds_n"] == "0":
                native_latches.append((int(x["address"]), int(x["data_out"]) >> 8, 65280))
    reference_latches = [(int(x["address"]), int(x["data"]) >> 8, int(x["mask"])) for x in events if x["area"] == "sound_latch_write"]
    checks["main_sound_latch_ordered_data_exact"] = native_latches == reference_latches
    checks["finite_actual_coin_start_and_movement_inputs_nonvacuous"] = any(int(x["coins_n"]) != 3 for x in applied) and any(int(x["controls"]) != 0 for x in applied)
    checks["720_main_and_sound_CPU_transaction_progress"] = int(fields[-1]["main_transactions"]) > int(fields[0]["main_transactions"]) and len(sound_native) > 0
    checks["PCM_captured_even_length_nonempty"] = (T / "audio.pcm").exists() and (T / "audio.pcm").stat().st_size > 0 and (T / "audio.pcm").stat().st_size % 2 == 0
    result = {"scope": "Actual joined profile1 cold boot/coin/start/play and finite sound/graphics compatibility; no broad gameplay-effects, death/reset, P7/P8, resource/timing or hardware acceptance.",
              "checks": checks, "all_checks_strict_true": all(v is True for v in checks.values()),
              "failed_checks": [k for k, v in checks.items() if v is not True],
              "fields": len(fields), "worst_line_cycles": max(int(x["worst_line_cycles"]) for x in fields),
              "arrays": arrays, "sound_writes_reference_native": [len(sound_ref), len(sound_native)],
              "DAC_writes_reference_native": [len(dac_ref), len(dac_native)],
              "latches_reference_native": [len(reference_latches), len(native_latches)],
              "first_port_difference": differences[0] if differences else None,
              "prepared_source_manifest_sha256": sha(P), "actual_native_exit": terminal,
              "limitations": ["Button/input pulses do not prove every successful hit/pickup/jump or death/restart effect.", "PCM phase equality is not required; capture is retained for mix/rate analysis.", "IRQ/NMI source clock identities remain pinned; physical clock and full audio calibration are separate gates."]}
    write("verification.json", result)
    print(json.dumps({"checks": len(checks), "failed_checks": result["failed_checks"], "fields": len(fields), "verification_sha256": sha(N / "verification.json")}))
    return 0 if result["all_checks_strict_true"] else 1
def supervise():
    p = check_pins()
    command = p["command"]
    at = command.index("--exec")
    wrapped = command[:at + 1] + ["/bin/bash", "-c", 'printf "linux_pid=%s\\n" "$$"; exec "$@"', "japan_joined720"] + command[at + 1:]
    with (N / "run.log").open("wb") as log:
        child = subprocess.Popen(wrapped, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        write("run_job.json", {"pid": child.pid, "supervisor_pid": os.getpid(), "started": time.time(), "command": wrapped, "preparation_sha256": sha(P), "ELF_sha256": p["ELF"]["sha256"]})
        code = child.wait()
    native_pid = re.search(r"linux_pid=(\d+)", (N / "run.log").read_text(errors="replace"))
    write("run_exit.json", {"exit_code": code, "finished": time.time(), "WSL_pid": child.pid, "Linux_pid": int(native_pid.group(1)) if native_pid else None, "ELF_sha256": sha(Path(p["ELF"]["path"])), "log_sha256": sha(N / "run.log")})
    with (N / "verification.log").open("wb") as log:
        verifier = subprocess.Popen([sys.executable, str(Path(__file__)), "verify"], stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        write("verification_job.json", {"pid": verifier.pid, "started": time.time(), "supervisor_pid": os.getpid(), "verifier_sha256": sha(Path(__file__))})
        vcode = verifier.wait()
    write("verification_exit.json", {"exit_code": vcode, "finished": time.time(), "log_sha256": sha(N / "verification.log")})
    write("supervisor_exit.json", {"run_exit_code": code, "verification_exit_code": vcode, "finished": time.time()})
    return vcode
def admit():
    p = check_pins()
    assert not N.exists(), "Existing namespace: refuse duplicate admission"
    observed = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--exec", "/bin/ps", "-eo", "pid,args"], capture_output=True, text=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
    assert observed.returncode == 0, observed.stderr
    duplicates = [x for x in observed.stdout.splitlines() if "alpha68kn_system_sim" in x and ("remaining_gates_20261011/japan_joined720" in x or ("kyrosj/download.bin" in x and " 720 " in x))]
    assert not duplicates, duplicates
    N.mkdir(parents=True)
    write("admission.json", {"authorized_by": "Root task instruction: execute ONE prepared Japan720 joined replay, no rebuild.", "time": time.time(), "native_ps_exit_code": observed.returncode, "duplicate_matches": duplicates, "source75_verified": True, "ELF_sha256": p["ELF"]["sha256"], "preparation_sha256": sha(P), "worker_sha256": sha(Path(__file__))})
    with (N / "supervisor.log").open("wb") as log:
        worker = subprocess.Popen([sys.executable, str(Path(__file__)), "supervise"], stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP)
    write("supervisor.json", {"pid": worker.pid, "started": time.time(), "script": str(Path(__file__)), "script_sha256": sha(Path(__file__))})
    print(json.dumps({"supervisor_pid": worker.pid, "namespace": str(N), "admitted": True, "duplicate_matches": 0, "rebuild": False}))
    return 0

if __name__ == "__main__":
    mode = sys.argv[1]
    raise SystemExit({"admit": admit, "supervise": supervise, "verify": verify}[mode]())
