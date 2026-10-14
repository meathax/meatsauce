"""Freeze separated terminal domains without clearing strict work-RAM failures."""
from pathlib import Path
import hashlib, json
O = Path(__file__).resolve().parent
N = O / "japan_joined720"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
v = js(N / "verification_canonical_v2.json")
ex = js(N / "verification_canonical_v2_exit.json")
job = js(N / "verification_canonical_v2_job.json")
assert ex["exit_code"] == 1 and not v["all_checks_strict_true"]
assert set(v["failed_checks"]) == {"all18_full_RGB_work_strip_arrays_exact", "all6_work_arrays_exact"}
assert job["verifier_sha256"] == sha(O / "verify_japan_canonical_v2.py")
assert job["preparation_sha256"] == sha(N / "canonical_v2_preparation.json")
assert ex["log_sha256"] == sha(N / "verification_canonical_v2.log")
assert sha(N / "import_manifest.json") == "238bf75296e6d263d14e7ff8b415a2a8f128f7231127d6eb2ca568dd5b55218c"
assert sha(N / "supplement_import_manifest.json") == "3248d170ae86ce7bc51df83e67a77d2e1e7da29691234dbe395589f29d6a12ce"
assert v["array_class_results"]["RGB"]["passed"] and v["array_class_results"]["strip"]["passed"] and not v["array_class_results"]["work"]["passed"]
assert v["sound_writes_reference_native"] == [406, 406] and v["DAC_writes_reference_native"] == [29549, 29549] and v["latches_reference_native"] == [9, 9]
rom = js(N / "work_ROM_candidates.json")
assert rom["payload_main_ROM_bytes_exact"] and not rom["current_SP_known"] and not rom["proven_stale_stack_values"]
files = [O / x for x in ("prepare_verify_canonical_v2.py", "verify_japan_canonical_v2.py", "map_japan_work_rom.py", "freeze_canonical_v2.py")]
files += [N / x for x in ("canonical_v2_preparation.json", "verification_canonical_v2_job.json", "verification_canonical_v2_exit.json", "verification_canonical_v2.log", "verification_canonical_v2.json", "work_ROM_candidates.json", "work_difference_table.md")]
domains = {k: {"fields": 6, "pass": v["array_class_results"][k]["passed"], "different_bytes": [{"field": x["field"], "count": x["different_bytes"]} for x in v["array_class_results"][k]["arrays"]]} for k in ("RGB", "strip", "work")}
domains.update({"chip_registers": {"reference_writes": 406, "native_writes": 406, "data_and_field_labels_exact": True}, "DAC": {"reference_writes": 29549, "native_writes": 29549, "ordered_data_exact": True}, "main_sound_latches": {"reference_writes": 9, "native_writes": 9, "ordered_data_exact": True}, "source": {"frozen_files": 75, "same_ELF_ROM_inputs": v["checks"]["frozen75_sources_ELF_ROM_input_reference_pins"]}, "input": {"same_original_ports_at_snapshot_boundary": v["checks"]["all_actual_ports_at_original_snapshot_boundary"]}, "protocol": {"native_exit0": v["checks"]["actual_native_exit0"], "fields": v["fields"], "contiguous": v["checks"]["720_contiguous_native_fields"], "57344pixels_no_duplicates_deadlines_overflows_unmapped": v["checks"]["all_pixels57344_no_duplicates_deadlines_overflows_unmapped"], "worst_line_cycles": v["worst_line_cycles"]}})
output = N / "canonical_v2_import_manifest.json"
assert not output.exists()
result = {"scope": "One separately pinned verifier consumer correction against the completed720 capture, plus bounded offline loadedROM mapping. No replay, build, production source edit or acceptance loosening.", "original_failure_import": pin(N / "import_manifest.json"), "original_diagnosis_import": pin(N / "supplement_import_manifest.json"), "actual_native_exit": 0, "actual_v2_verifier_exit": ex["exit_code"], "checks_true": sum(x is True for x in v["checks"].values()), "checks_total": len(v["checks"]), "failed_checks": v["failed_checks"], "strict_joined_Japan_acceptance": False, "domain_results": domains, "small_import_files": [pin(p) for p in files], "canonical_reference_pins": v["canonical_reference_pins"], "work_ROM_mapping": {"loaded_mainROM_bytes_exact": True, "candidate_call_return_matches": 0, "actual_current_SP_known": False, "proven_stale_stack": False}, "limitations": v["limitations"] + rom["limits"] + ["Eight upper-workRAM byte differences remain open; they do not identify an RTL fault or establish stale-stack status. The original13of14 exit1 failure remains immutable."]}
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"path": str(output), "sha256": sha(output), "actual_verifier_exit": ex["exit_code"], "checks_true_total": [result["checks_true"], result["checks_total"]], "RGB_fields_pass": 6, "strip_fields_pass": 6, "work_fields_pass": 3, "remaining_work_bytes": [3,1,4], "import_files": len(files)}))
