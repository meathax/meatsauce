# SPDX-License-Identifier: GPL-2.0-or-later
"""Reject incomplete per-condition timing measurements before judging slack."""
from pathlib import Path
import csv
import math
import re

CHECKS = ("setup", "hold", "recovery", "removal")

def evaluate_corner_coverage(rows, conditions, completed_count, collection_errors=()):
    errors = list(collection_errors)
    names = {row.get("corner") for row in rows}
    if not names or None in names or "" in names:
        errors.append("Missing operating-condition name")
    if not isinstance(completed_count, int) or completed_count <= 0 or len(names) != completed_count:
        errors.append("Operating-condition count does not match completed collection")
    if names != set(conditions):
        errors.append("Condition/pulse reports do not match CSV operating conditions")
    values = {check: [] for check in CHECKS}
    for name in sorted(names, key=str):
        entries = [row for row in rows if row.get("corner") == name]
        if len({(r.get("model"), r.get("temperature"), r.get("voltage")) for r in entries}) != 1:
            errors.append(f"{name}: inconsistent operating-condition metadata")
        if any(r.get("check") not in CHECKS for r in entries):
            errors.append(f"{name}: unexpected timing check")
        for check in CHECKS:
            matches = [r for r in entries if r.get("check") == check]
            if len(matches) != 1:
                errors.append(f"{name}: expected one {check} row, found {len(matches)}")
                continue
            try:
                value = float(matches[0]["worst_slack_ns"])
                paths = int(matches[0]["paths"])
                if not math.isfinite(value) or paths <= 0:
                    raise ValueError("No finite applicable measurement")
            except (ValueError, TypeError, KeyError):
                errors.append(f"{name}: missing/invalid {check} measurement")
                continue
            values[check].append(value)
    pulses = []
    for name, value in conditions.items():
        if value is None or not math.isfinite(value):
            errors.append(f"{name}: missing/invalid minimum-pulse-width measurement")
        else:
            pulses.append(value)
    minima = {check: min(v) if v else None for check, v in values.items()}
    minima["minimum_pulse_width"] = min(pulses) if pulses else None
    complete = not errors
    return {
        "measured_operating_conditions": len(names),
        "corner_collection_complete": complete,
        "corner_coverage_errors": errors,
        "all_corner_min_slack_ns": minima,
        "all_applicable_corners_qualified": complete and all(v is not None and v >= 0 for v in minima.values()),
    }

def read_corner_gate(root, completion_log):
    root = Path(root)
    with (root / "corners.csv").open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    text = Path(completion_log).read_text(errors="replace") if Path(completion_log).exists() else ""
    matches = re.findall(r"Collected (\d+) device operating conditions\.", text)
    completed = int(matches[0]) if len(matches) == 1 else None
    conditions, errors = {}, []
    for folder in sorted(root.glob("corner_*")):
        if not folder.is_dir():
            continue
        try:
            name = (folder / "condition.txt").read_text().splitlines()[0].strip()
        except (OSError, IndexError):
            errors.append(f"{folder.name}: missing condition identity")
            continue
        if name in conditions:
            errors.append(f"Duplicate condition report: {name}")
        pulse = folder / "min_pulse_width.txt"
        content = pulse.read_text(errors="replace") if pulse.exists() else ""
        match = re.search(r"Worst case slack is ([^\s]+)", content)
        try:
            value = float(match[1]) if match else None
        except ValueError:
            value = None
        conditions[name] = value
    return evaluate_corner_coverage(rows, conditions, completed, errors)
