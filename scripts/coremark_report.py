"""Summarize the benchmark runs from scripts/run_coremark.ps1.

Reads build/coremark/xsim_<program>_<variant>/coremark.log for CoreMark and the
S3 FIR benchmark (no prediction, the BTB/BHT without JALR prediction, and the
full predictor), copies the logs to
results/coremark/ and writes results/coremark/summary.txt with, per run: CPI
(cycles / retired instructions), control transfers resolved (branch, JAL,
JALR), mispredictions and their rate, redirects, JALRs and returns (JALR with
rd = x0, rs1 = x1 or x5) resolved and mispredicted, and for CoreMark
CoreMark/MHz (iterations * 10^6 / ticks, ticks = mcycle cycles in the timed
region).
"""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/coremark"
OUT = ROOT / "results/coremark"
DONE = re.compile(r"COREMARK_TB_DONE cycles=(\d+) retired=(\d+) redirects=(\d+) branches=(\d+) mispredicts=(\d+) "
                  r"jalrs=(\d+) jalr_mispredicts=(\d+) returns=(\d+) return_mispredicts=(\d+)")


def parse(text, program):
    done = DONE.search(text)
    if not done:
        raise AssertionError("no COREMARK_TB_DONE line")
    run = dict(zip(("cycles", "retired", "redirects", "branches", "mispredicts",
                    "jalrs", "jalr_mispredicts", "returns", "return_mispredicts"), map(int, done.groups())))
    if program == "coremark":
        run["ticks"] = int(re.search(r"^Total ticks\s*:\s*(\d+)", text, re.M).group(1))
        run["iterations"] = int(re.search(r"^Iterations\s*:\s*(\d+)", text, re.M).group(1))
    return run


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    runs = {}
    for program in ("fir", "coremark"):
        for variant in ("nobpred", "nojalr", "bpred"):
            log = BUILD / f"xsim_{program}_{variant}/coremark.log"
            shutil.copy(log, OUT / f"{program}_{variant}.log")
            runs[program, variant] = parse(log.read_text(), program)
    shutil.copy(BUILD / "flags.txt", OUT / "flags.txt")
    lines = ["program  variant  cycles     retired    CPI    branches  mispredicts rate    redirects CoreMark/MHz "
             "jalrs  jalr_miss returns return_miss"]
    for (program, variant), r in runs.items():
        r["cpi"] = r["cycles"] / r["retired"]
        r["rate"] = r["mispredicts"] / r["branches"]
        score = f"{r['iterations'] * 1e6 / r['ticks']:12.3f}" if program == "coremark" else f"{'-':>12}"
        if program == "coremark":
            r["score"] = r["iterations"] * 1e6 / r["ticks"]
        lines.append(f"{program:8} {variant:8} {r['cycles']:10d} {r['retired']:10d} {r['cpi']:6.3f} "
                     f"{r['branches']:9d} {r['mispredicts']:11d} {r['rate'] * 100:6.2f}% {r['redirects']:9d} {score} "
                     f"{r['jalrs']:6d} {r['jalr_mispredicts']:9d} {r['returns']:7d} {r['return_mispredicts']:11d}")
    # SUMMARY: no prediction -> full predictor; JALR: the same predictor
    # without -> with JALR prediction (return-address stack, BTB targets).
    for label, base in (("SUMMARY", "nobpred"), ("JALR", "nojalr")):
        for program in ("fir", "coremark"):
            before, after = runs[program, base], runs[program, "bpred"]
            extra = f" coremark_speedup={after['score'] / before['score']:.3f}" if program == "coremark" else ""
            lines.append(f"{label} {program} cpi {before['cpi']:.3f}->{after['cpi']:.3f} "
                         f"mispredict_rate {before['rate'] * 100:.2f}%->{after['rate'] * 100:.2f}% "
                         f"cycles -{(1 - after['cycles'] / before['cycles']) * 100:.1f}%{extra}")
    (OUT / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
