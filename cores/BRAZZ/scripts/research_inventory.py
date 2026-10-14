"""Bounded, recoverable evidence for the donor survey and reference version."""
import concurrent.futures
import hashlib
import json
import pathlib
import urllib.parse
import xml.etree.ElementTree as ET

from prepare_sources import ROOT, request


def main():
    report = {"date": "2026-10-04", "queries": [], "mame_source_comparison": []}
    for query in ["se3208", "vrender0", "CrystalSystem FPGA", "ds1302 verilog", "pic16c57 verilog"]:
        url = "https://api.github.com/search/repositories?per_page=12&q=" + urllib.parse.quote(query)
        try:
            data = json.loads(request(url))
            report["queries"].append({"query": query, "url": url, "total_count": data["total_count"], "results": [
                {"repository": x["full_name"], "url": x["html_url"], "description": x.get("description"), "license": (x.get("license") or {}).get("spdx_id")}
                for x in data["items"]]})
        except Exception as error:
            report["queries"].append({"query": query, "url": url, "error": f"{type(error).__name__}: {error}"})
    paths = ["src/mame/misc/crystal.cpp", "src/devices/cpu/se3208/se3208.cpp", "src/devices/machine/vrender0.cpp",
             "src/devices/machine/vr0uart.cpp", "src/devices/video/vrender0.cpp", "src/devices/sound/vrender0.cpp", "src/devices/machine/ds1302.cpp"]
    def compare(relative):
        url = "https://raw.githubusercontent.com/mamedev/mame/mame0289/" + relative
        entry = {"path": relative, "url": url}
        try:
            upstream = request(url)
            local = (ROOT / "docs/reference/mame" / relative).read_bytes()
            # Ignore platform newline conversion, while retaining raw hashes.
            entry.update(local_sha256=hashlib.sha256(local).hexdigest(), upstream_sha256=hashlib.sha256(upstream).hexdigest(),
                         matches_after_newline_normalization=local.replace(b"\r\n", b"\n") == upstream.replace(b"\r\n", b"\n"))
            if not entry["matches_after_newline_normalization"]:
                target = ROOT / "docs/reference/mame/upstream_mame0289" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(upstream)
        except Exception as error:
            entry["error"] = f"{type(error).__name__}: {error}"
        return entry
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        report["mame_source_comparison"] = list(executor.map(compare, paths))
    jt = ROOT / "donors/jtframe/.gitmodules"
    if jt.exists():
        report["jtcores_submodules"] = jt.read_text(encoding="utf-8")
    (ROOT / "docs/research_log.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tree = ET.parse(ROOT / "docs/reference/mame/mame_listxml.txt")
    game = next(x for x in tree.getroot().findall("machine") if x.attrib["name"] == "crysking")
    facts = {"machine": game.attrib, "chips": [x.attrib for x in game.findall("chip")], "display": [x.attrib for x in game.findall("display")],
             "bios": [x.attrib for x in game.findall("biosset")], "input": ET.tostring(game.find("input"), encoding="unicode"),
             "roms": [x.attrib for x in game.findall("rom")], "driver": game.find("driver").attrib}
    (ROOT / "docs/mame_machine.json").write_text(json.dumps(facts, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"queries": report["queries"], "source_comparison": [{"path": x["path"], "matches": x.get("matches_after_newline_normalization"), "error": x.get("error")} for x in report["mame_source_comparison"]],
                      "chips": facts["chips"], "display": facts["display"], "driver": facts["driver"]}, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
