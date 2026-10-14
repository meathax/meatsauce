#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Invoke explicitly with /bin/bash in Ubuntu WSL. The Linux parent records
# the child's actual exit even if the Windows observation wrapper disappears.
if [ "$#" -lt 2 ]; then exit 64; fi
receipt=$1
shift
"$@"
native_status=$?
printf '%s\n' "$native_status" > "${receipt}.tmp"
mv -- "${receipt}.tmp" "$receipt" || exit 74
exit "$native_status"
