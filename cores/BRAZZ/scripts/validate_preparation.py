"""One decisive audit of the prepared project; does not validate game RTL."""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
GIT = r"C:\Program Files\Git\cmd\git.exe"


def main():
    checks = []
    def check(name, passed, evidence=None):
        checks.append({"check": name, "passed": bool(passed), "evidence": evidence})
    required = ["CrystalSystem.qpf", "CrystalSystem.qsf", "CrystalSystem.sdc", "CrystalSystem.sv", "files.qip", "sys/sys_top.v",
                "plan.md", "progress.md", "goal_prompt.md", "AGENTS.md", "docs/HARDWARE_NOTES.md", "docs/DONOR_MAP.md", "donors/manifest.json"]
    check("project and planning artifacts exist", all((ROOT / p).is_file() for p in required), required)
    check("project revision renamed", 'PROJECT_REVISION = "CrystalSystem"' in (ROOT / "CrystalSystem.qpf").read_text())
    check("file list targets renamed wrapper and constraints", all(x in (ROOT / "files.qip").read_text() for x in ["CrystalSystem.sv", "CrystalSystem.sdc"]))
    diff = subprocess.run([GIT, "diff", "--name-only", "HEAD", "--", "sys"], cwd=ROOT, capture_output=True, text=True)
    check("upstream sys unchanged", diff.returncode == 0 and not diff.stdout.strip(), {"exit_code": diff.returncode, "output": diff.stdout.strip(), "stderr": diff.stderr.strip()})
    ignored = subprocess.run([GIT, "check-ignore", "roms/crysking.zip", "roms/crysbios.zip", "mister.env", "donors/saturn/rtl/Saturn/VDP1/VDP1.sv"], cwd=ROOT, capture_output=True, text=True)
    check("ROMs machine config and donor snapshots ignored", ignored.returncode == 0 and len(ignored.stdout.splitlines()) == 4, ignored.stdout.splitlines())
    manifest = json.loads((ROOT / "donors/manifest.json").read_text())
    for d in manifest:
        folder = ROOT / "donors" / d["name"]
        listed = json.loads((folder / "FILES.json").read_text()) if (folder / "FILES.json").exists() else []
        prov = json.loads((folder / "PROVENANCE.json").read_text()) if (folder / "PROVENANCE.json").exists() else {}
        check("staged donor " + d["name"], d["status"] == "staged" and len(listed) == d["files"] and all((folder / f).is_file() for f in listed)
              and prov.get("revision") == d.get("revision") and len(d.get("revision", "")) == 40,
              {"revision": d.get("revision"), "files": len(listed), "classification": "source/reference; not integrated or simulation-tested"})
    check("nine selected snapshots", len(manifest) == 9)
    for r in json.loads((ROOT / "docs/rom_manifest.json").read_text()):
        path = ROOT / "roms" / r["archive"]
        check("ROM source archive unchanged " + r["archive"], hashlib.sha256(path.read_bytes()).hexdigest() == r["sha256"], r["sha256"])
    commands = json.loads((ROOT / "docs/reference/mame/MAME_COMMANDS.json").read_text())
    check("full MAME audit and listxml successful", all(x["exit_code"] == 0 and x["stderr_bytes"] == 0 for x in commands["commands"].values()), commands)
    version = (ROOT / "docs/reference/mame/mame_version.txt").read_text().strip()
    check("oracle is official MAME 0.289", version == "0.289 (mame0289)", version)
    research = json.loads((ROOT / "docs/research_log.json").read_text(encoding="utf-8"))
    comparisons = research["mame_source_comparison"]
    check("seven key sources match official MAME tag", len(comparisons) == 7 and all(x.get("matches_after_newline_normalization") for x in comparisons))
    for r in json.loads((ROOT / "docs/reference/mame/SOURCE_MANIFEST.json").read_text()):
        file = ROOT / "docs/reference/mame" / r["path"]
        check("reference unchanged " + r["path"], file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == r["sha256"])
    check("capture board profile is little-endian 32-bit", (lambda c: c["bus_bytes"] == 4 and c["big_endian"] is False)(json.loads((ROOT / "scripts/mame/regions.json").read_text())))
    result = {"scope": "project/source/ROM/plan preparation only", "passed": all(x["passed"] for x in checks), "checks": checks}
    (ROOT / "docs/preparation_check.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": result["passed"], "checks": len(checks), "failed": [x for x in checks if not x["passed"]], "evidence": "docs/preparation_check.json", "donors": len(manifest)}, indent=2))
    return int(not result["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
