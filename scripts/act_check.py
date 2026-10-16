"""Judge the riscv-arch-test (ACT4) runs.

RTL: a test passes only if pipe_tb finished cleanly (CORE_TB_DONE, no
Fatal/Error) and the final memory dump holds 1 in tohost, which
RVMODEL_HALT_PASS writes after the test's own Sail-derived self-checks.
Spike (--spike): the same ELF on Spike, which exits 0 only when tohost == 1.
Writes results/act4/rtl.csv (and spike.csv) and prints one line per test.
"""
import argparse
import csv
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGES = ROOT / "build/act4/images"
OUT = ROOT / "results/act4"
SPIKE_ISA = "rv64im_zicsr_zifencei"
SPIKE_MEM = "-m0x80000000:0x40000"


def rtl_result(entry, seed, max_delay, xsim):
    name = f"{entry['test']}_s{seed}_d{max_delay}"
    log = xsim / f"{name}.log"
    mem = xsim / f"{name}.csv.mem"
    if not log.exists():
        return "NOT_RUN", "no simulation log"
    text = log.read_text(errors="replace")
    fatal = re.search(r"(?m)^\s*(Fatal|Error):.*$", text)
    if fatal:
        return "FAIL", fatal.group(0).strip()[:160]
    done = re.search(r"CORE_TB_DONE cycles=(\d+) retired=(\d+)", text)
    if not done or not mem.exists():
        return "FAIL", "simulation did not reach CORE_TB_DONE"
    data = mem.read_text().split()
    off = entry["tohost_offset"]
    tohost = int.from_bytes(bytes(int(b, 16) for b in data[off:off + 8]), "little")
    detail = f"tohost={tohost} cycles={done.group(1)} retired={done.group(2)}"
    if tohost == 1:
        return "PASS", detail
    if tohost == 3:
        return "FAIL", "self-check failed; " + detail
    return "FAIL", "halted without a result; " + detail


def spike_result(entry):
    try:
        run = subprocess.run(["spike", f"--isa={SPIKE_ISA}", SPIKE_MEM, entry["elf"]], cwd=ROOT,
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return "FAIL", "timeout"
    if run.returncode == 0:
        return "PASS", ""
    return "FAIL", f"exit {run.returncode} {run.stderr.strip()[:120]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-delay", type=int, default=5)
    ap.add_argument("--label", default="", help="mutant label: reads build/xsim_act_<label>, writes rtl-<label>.csv")
    ap.add_argument("--spike", action="store_true", help="run the ELFs on Spike instead of judging the RTL runs")
    args = ap.parse_args()
    entries = json.loads((IMAGES / "manifest.json").read_text())
    OUT.mkdir(parents=True, exist_ok=True)
    kind = "spike" if args.spike else "rtl"
    xsim = ROOT / (f"build/xsim_act_{args.label}" if args.label else "build/xsim_act")
    stem = f"{kind}-{args.label}" if args.label else kind
    rows = []
    for entry in entries:
        status, detail = spike_result(entry) if args.spike else rtl_result(entry, args.seed, args.max_delay, xsim)
        rows.append({"test": entry["test"], "suite": entry["suite"], "status": status, "detail": detail})
        print(f"ACT_{kind.upper()}_{status} {entry['test']} {detail}".rstrip())
    with (OUT / f"{stem}.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["test", "suite", "status", "detail"])
        w.writeheader()
        w.writerows(rows)
    for suite in sorted({r["suite"] for r in rows}):
        sel = [r for r in rows if r["suite"] == suite]
        print(f"ACT_{kind.upper()}_SUMMARY suite={suite} pass={sum(r['status'] == 'PASS' for r in sel)} of {len(sel)}")
    failed = [r for r in rows if r["status"] != "PASS"]
    print(f"ACT_{kind.upper()}_TOTAL pass={len(rows) - len(failed)} of {len(rows)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
