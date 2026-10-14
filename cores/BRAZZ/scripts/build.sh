#!/usr/bin/env bash
# Compile the core IN-TREE and REPORT THE TIMING, not just the exit code.
#
#     scripts/build.sh            # full compile
#     scripts/build.sh --map      # refused; use a complete queued preassembly recipe
#     scripts/build.sh --report   # re-read the last build's reports, compile nothing
#
# Quartus reports "Fitter was successful" on a design that grossly fails
# timing, and nothing in the default flow warns you -- so output_files/<rev>.sta.summary
# is read here, every time, and a timing failure is as loud as a syntax error.
#
# Prefer scripts/build_staged.py: it builds HEAD in a worktree and leaves the
# tree free. This one sees uncommitted work and needs the tree left alone.
set -euo pipefail

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

# The fixed shared worker resolves Quartus; no native tool is launched here.
# The revision: CORE_REV, else the one .qsf in the core root.
REV="${CORE_REV:-$(ls *.qsf 2>/dev/null | head -1 | sed "s/\.qsf$//")}"
[ -n "$REV" ] || { echo "no .qsf here: run from the core root"; exit 1; }
OUT=output_files

mode="${1:-full}"

if [ "$mode" != "--report" ]; then
	# The other half of scripts/hwlock.py: no compile while a JTAG tool reads.
	python scripts/hwlock.py --require-no-jtag "build.sh $REV"
	mkdir -p "$OUT"
	[ "$mode" != "--map" ] || { echo "Separate map jobs are refused. Use a complete queued preassembly recipe."; exit 2; }
	[ "$mode" = "full" ] || { echo "Unsupported build mode"; exit 2; }
	# The project's PRE_FLOW_SCRIPT_FILE generates build_id.v inside the same job.
	grep -qE 'PRE_FLOW_SCRIPT_FILE.*sys/build_id\.tcl' "$REV.qsf" || {
		echo "Missing reviewed PRE_FLOW_SCRIPT_FILE; refuse to invent a separate build-ID job."; exit 2; }
	QUEUE_HELPER='C:/Users/meath/.claude/skills/mister-rbf-build/scripts/shared_quartus_full_compile.py'
	if command -v wslpath >/dev/null 2>&1; then QUEUE_HELPER="$(wslpath -u "$QUEUE_HELPER")"
	elif command -v cygpath >/dev/null 2>&1; then QUEUE_HELPER="$(cygpath -u "$QUEUE_HELPER")"; fi
	python "$QUEUE_HELPER" --cwd "$PWD" --revision "$REV" --log "$OUT/build.log" || {
		echo "COMPILE FAILED"; grep -E "^Error|^\s+Error" "$OUT/build.log" | head -20; exit 1; }

fi

echo
echo "==== resource usage ===================================================="
# .fit.summary is a plain "key : value" list with no banner to key a range on.
grep -E "Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total DSP Blocks|Total pins|Total PLLs" \
	"$OUT/$REV.fit.summary" || echo "(no $OUT/$REV.fit.summary)"

echo
echo "==== timing ============================================================"
if [ -f "$OUT/$REV.sta.summary" ]; then
	cat "$OUT/$REV.sta.summary"
else
	echo "no $OUT/$REV.sta.summary -- STA did not run"
	exit 1
fi

# A negative slack anywhere is a failure, whatever the fitter said.
if grep -qE "Slack[[:space:]]*:[[:space:]]*-" "$OUT/$REV.sta.summary"; then
	echo
	echo "*** TIMING NOT MET -- negative slack above. The .rbf is not trustworthy. ***"
	exit 1
fi

echo
if [ -f "$OUT/$REV.rbf" ]; then
	ls -l "$OUT/$REV.rbf"
	echo "timing met."
else
	echo "no .rbf produced"
	exit 1
fi
