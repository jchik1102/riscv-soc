"""Copy the logs and reports that back the README numbers from build/ into
results/, and write results/summary.txt with totals derived from them.
Run after `make test` (and `make fpga` for the Quartus reports)."""
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
OUT = ROOT / "results"

CHECKER_JSON = ["trace_results.json", "trace_results_pipeline.json", "core_comparison.json",
                "fault_injection.json", "uvm_python_check.json", "instruction_coverage.json",
                "instruction_coverage_pipeline.json", "muldiv_mutants.json", "pipeline_mutants.json",
                "sdram_mutants.json", "cache_mutants.json", "accel_mutants.json"]
QUARTUS = BUILD / "quartus_board_s8_p1/output_files"
QUARTUS_FILES = ["de10_lite_s8_p1.fit.summary", "de10_lite_s8_p1.map.summary", "de10_lite_s8_p1.sta.summary",
                 "de10_lite_s8_p1.sta.rpt", "de10_lite_s8_p1.pow.summary"]


def copy(src, dst):
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return True
    print(f"MISSING {src.relative_to(ROOT)}")
    return False


def main():
    (OUT / "checkers").mkdir(parents=True, exist_ok=True)
    for name in CHECKER_JSON:
        copy(BUILD / name, OUT / "checkers" / name)
    for core in ("pipeline", "multicycle"):
        copy(BUILD / f"uvm_{core}/coverage_report/functionalCoverageReport/xcrg_func_cov_report.txt",
             OUT / "uvm" / f"coverage_{core}.txt")
        copy(BUILD / f"uvm_{core}/code_coverage.txt", OUT / "uvm" / f"code_coverage_{core}.txt")
    for name in QUARTUS_FILES:
        copy(QUARTUS / name, OUT / "quartus" / name)

    lines = []
    mutants = {}
    for kind in ("muldiv", "pipeline", "sdram", "cache", "accel"):
        path = BUILD / f"{kind}_mutants.json"
        if path.exists():
            rows = json.loads(path.read_text())
            mutants[kind] = (sum(r["result"] == "DETECTED" for r in rows), len(rows))
    if mutants:
        detected = sum(d for d, _ in mutants.values())
        total = sum(t for _, t in mutants.values())
        parts = ", ".join(f"{k} {d}/{t}" for k, (d, t) in mutants.items())
        lines.append(f"rtl_mutants_detected: {detected} of {total} ({parts})")

    sim_log = OUT / "test-sim.log"
    if sim_log.exists():
        text = sim_log.read_text(encoding="utf-8", errors="replace")
        for stage in ("S4", "S5", "S6", "S7", "S8"):
            records = [int(n) for n in re.findall(rf"^PASS {stage} SoC[^:]*: (\d+) records", text, re.M)]
            if records:
                lines.append(f"soc_{stage.lower()}: {len(records)} runs, {sum(records)} retirements checked")
        spike = len(re.findall(r"^PASS Spike/Python", text, re.M))
        skipped = len(re.findall(r"^SKIP Spike", text, re.M))
        lines.append(f"spike_programs: {spike} agree, {skipped} skipped by design")

    uvm_log = OUT / "test-uvm.log"
    if uvm_log.exists():
        text = uvm_log.read_text(encoding="utf-8", errors="replace")
        runs = len(re.findall(r"^UVM_RUN_PASS", text, re.M))
        errors = len(re.findall(r"UVM_(?:ERROR|FATAL) :\s*[1-9]", text))
        lines.append(f"uvm_runs: {runs} passed, {errors} runs reporting UVM errors or fatals")
    for core in ("pipeline", "multicycle"):
        path = OUT / "uvm" / f"code_coverage_{core}.txt"
        if path.exists():
            last = [l for l in path.read_text().splitlines() if l.startswith("CODE_COVERAGE ")]
            if last:
                lines.append(f"code_coverage_{core}: {last[-1].split(' ', 2)[2]}")

    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    header = [f"collected: {datetime.now().isoformat(timespec='seconds')}", f"commit: {commit}"]
    (OUT / "summary.txt").write_text("\n".join(header + lines) + "\n")
    print("\n".join(lines))
    print(f"COLLECTED into {OUT.relative_to(ROOT)}/")


if __name__ == "__main__":
    sys.exit(main())
