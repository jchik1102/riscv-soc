#!/usr/bin/env bash
# Run every SymbiYosys task listed in formal/tasks.txt ("<file>.sby <task>" per
# line) and copy each task's status and log into results/formal/.
# The tasks of one .sby file run in a single sby call, FORMAL_JOBS in parallel
# (default 8): separate parallel sby calls on one file race on its shared
# status database.
# Writes results/formal/summary.txt; exits 1 if any task is not PASS.
# Needs OSS CAD Suite (yosys, sby, the slang plugin, solvers) on PATH.
set -uo pipefail
# make does not read ~/.bashrc, so add a local OSS CAD Suite install if present.
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
cd "$(dirname "$0")/../formal"
OUT=../results/formal
mkdir -p "$OUT"
{ echo "OSS CAD Suite $(cat "$(dirname "$(command -v yosys)")/../VERSION" 2>/dev/null)"; yosys -V; sby --version
  echo "Yices $(yices --version | head -1 | awk '{print $2}')"; echo "Bitwuzla $(bitwuzla --version)"; } > "$OUT/versions.txt"

list=$(grep -vE '^\s*(#|$)' tasks.txt)
# Remove old work directories so a task that fails to start can't report a stale status.
echo "$list" | while read -r sby task; do rm -rf "${sby%.sby}_$task"; done
for sby in $(echo "$list" | awk '{print $1}' | sort -u); do
  sby -f -j "${FORMAL_JOBS:-8}" "$sby" $(echo "$list" | awk -v f="$sby" '$1==f {print $2}') < /dev/null > /dev/null 2>&1
done

: > "$OUT/summary.txt"
while read -r sby task; do
  name="${sby%.sby}_$task"
  result=$(cut -d' ' -f1 "$name/status" 2>/dev/null || echo ERROR)
  secs=$(grep -oE 'Elapsed clock time .*\([0-9]+\)' "$name/logfile.txt" 2>/dev/null | grep -oE '\([0-9]+\)' | tr -d '()')
  mkdir -p "$OUT/$name"
  cp "$name/logfile.txt" "$OUT/$name/" 2>/dev/null
  cp "$name/status" "$OUT/$name/" 2>/dev/null
  printf "%-40s %-7s %5ss\n" "$name" "$result" "${secs:-?}" | tee -a "$OUT/summary.txt"
done <<< "$list"
total=$(echo "$list" | wc -l); pass=$(awk '$2=="PASS"' "$OUT/summary.txt" | wc -l)
echo "FORMAL $pass of $total tasks PASS" | tee -a "$OUT/summary.txt"
[[ $pass -eq $total ]]
