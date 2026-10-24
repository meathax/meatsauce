#!/usr/bin/env bash
# Explicit local environment; never sources upstream user-home setup scripts.
set -euo pipefail
task_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export JTROOT="$task_root/donors/jtcores"
export JTFRAME="$JTROOT/modules/jtframe"
export CORES="$JTROOT/cores" MODULES="$JTROOT/modules"
export JTBIN="$task_root/build/jtbin" JTUTIL="$JTFRAME/src/jtutil"
export ROM="$task_root/roms"
exec "$task_root/scripts/jtframe-linux" "$@"
