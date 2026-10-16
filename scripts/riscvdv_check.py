"""Judge riscv-dv RTL runs and combine them with the Spike results.

A program passes when
  - pipe_tb ended cleanly (CORE_TB_DONE, no Fatal/Error),
  - scripts/check_pipeline_trace.py (the existing pipeline checker) accepts the RTL
    trace against the Python model, and
  - riscvdv_prepare.py found Spike's commits identical to the same model.
Writes <dir>/results.json and prints one line per program plus totals.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-delay", type=int, default=5)
    args = ap.parse_args()
    d = ROOT / args.dir
    manifest = json.loads((d / "manifest.json").read_text())
    spike = {s["program"]: s for s in json.loads((d / "spike.json").read_text())}
    results = []
    for entry in manifest:
        name = entry["program"]
        row = {"program": name, "bytes": entry.get("bytes")}
        if entry["status"] != "READY":
            row.update(result="NOT_RUN", reason=entry["status"])
        else:
            sim = f"{name}_s{args.seed}_d{args.max_delay}"
            log = d / "xsim" / f"{sim}.log"
            text = log.read_text(errors="replace") if log.exists() else ""
            fatal = re.search(r"(?m)^\s*(Fatal|Error):.*$", text)
            if not log.exists():
                row.update(result="FAIL", reason="no simulation log")
            elif fatal:
                row.update(result="FAIL", reason=fatal.group(0).strip()[:200])
            elif "CORE_TB_DONE" not in text:
                row.update(result="FAIL", reason="simulation did not reach CORE_TB_DONE")
            else:
                check = subprocess.run([sys.executable, "scripts/check_pipeline_trace.py", str(d / "images" / f"{name}.hex"),
                                        str(d / "xsim" / f"{sim}.csv")], cwd=ROOT, capture_output=True, text=True)
                rtl_ok = check.returncode == 0
                # Retired records and where traps happened. riscv-dv's handler ends
                # the test on an unexpected load/store fault, so a fault far before
                # the end means most of the program never ran.
                retired, traps = 0, []
                for line in (d / "xsim" / f"{sim}.csv").read_text().splitlines()[1:]:
                    fields = line.split(",")
                    if fields[0].isdigit():
                        retired += 1
                        if fields[11] == "1":
                            traps.append(f"{retired}:cause{fields[12]}")
                row.update(records=retired, traps=traps)
                spike_ok = spike.get(name, {}).get("result") == "PASS"
                row.update(rtl_vs_model=check.stdout.strip() if rtl_ok else (check.stdout + check.stderr).strip()[-300:],
                           spike_vs_model=spike.get(name, {}).get("result", "MISSING"),
                           register_commits=spike.get(name, {}).get("register_commits"))
                row["result"] = "PASS" if rtl_ok and spike_ok else "FAIL"
                if not rtl_ok:
                    row["reason"] = "RTL trace rejected by check_pipeline_trace.py"
                elif not spike_ok:
                    row["reason"] = "Spike disagrees with the model: " + spike.get(name, {}).get("error", "")[:200]
        results.append(row)
        extra = f" records={row['records']} traps={','.join(row['traps'])}" if "records" in row else ""
        print(f"RISCVDV_{row['result']} {name} {row.get('reason', row.get('rtl_vs_model', ''))}{extra}".rstrip())
    (d / "results.json").write_text(json.dumps(results, indent=1))
    ran = [r for r in results if r["result"] != "NOT_RUN"]
    passed = sum(r["result"] == "PASS" for r in ran)
    commits = sum(r.get("register_commits") or 0 for r in ran if r["result"] == "PASS")
    print(f"RISCVDV_TOTAL pass={passed} of {len(ran)} programs; not run={len(results) - len(ran)}; "
          f"{commits} Spike-matched register commits in passing programs")
    return 0 if passed == len(ran) else 1


if __name__ == "__main__":
    raise SystemExit(main())
