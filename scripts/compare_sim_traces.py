"""Compare the CPU traces from Questa (build/questa/core, build/questa/pipe)
with XSim's (build/xsim_core, build/xsim_pipe), file for file: every retired
instruction, bus request and response, reset marker, and the final memory dump.

    python scripts/compare_sim_traces.py [--out build/questa/trace_compare.json]

Both sets must come from the same sources and the same regression matrices
(scripts/run_questa.ps1 -Only cores, and the core part of scripts/regress.ps1).
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIRS = (("multicycle", "build/questa/core", "build/xsim_core"), ("pipeline", "build/questa/pipe", "build/xsim_pipe"))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="build/questa/trace_compare.json")
    args = p.parse_args()
    report, failed = {}, False
    for core, questa, xsim in PAIRS:
        files = sorted((ROOT / questa).glob("*.csv")) + sorted((ROOT / questa).glob("*.csv.mem"))
        if not files:
            raise SystemExit(f"No Questa traces in {questa}")
        same, differ, missing, lines = 0, [], [], 0
        for f in files:
            other = ROOT / xsim / f.name
            if not other.exists():
                missing.append(f.name)
                continue
            a, b = f.read_bytes().replace(b"\r\n", b"\n"), other.read_bytes().replace(b"\r\n", b"\n")
            if a == b:
                same += 1
                if f.suffix == ".csv":
                    lines += a.count(b"\n") - 1
            else:
                differ.append(f.name)
        traces = sum(1 for f in files if f.suffix == ".csv")
        report[core] = dict(files=len(files), traces=traces, identical=same, trace_lines=lines, differ=differ, missing=missing)
        print(f"{core}: {same} of {len(files)} files identical ({traces} traces, {lines} trace lines); "
              f"{len(differ)} differ, {len(missing)} missing in XSim")
        failed |= bool(differ or missing)
    (ROOT / args.out).write_text(json.dumps(report, indent=2) + "\n")
    print("TRACES_IDENTICAL" if not failed else "TRACES_DIFFER")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
