#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
mkdir -p results
make cpu-run >results/cpu-build.log 2>&1
task_status=$?
if [ "$task_status" -eq 0 ]; then
    cat results/cpu-boot.json
else
    tail -n 18 results/cpu-build.log
fi
exit "$task_status"
