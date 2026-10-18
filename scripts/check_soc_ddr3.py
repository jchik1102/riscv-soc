"""Check the DDR3 SoC runs (tb/ddr3/soc_ddr3_tb.sv, scripts/run_soc_ddr3.ps1).

Each transcript goes through the same cache-aware model as the S6 SoC runs
(model.cache_check.compare_cached): every retirement, every core bus access
and every cache line fill or uncached access on the memory side. Then, for a
run with no interrupts and no MMIO reads (whose values depend on timing), its
retirements must be identical to the SDR SDRAM run of the same program in
build/xsim_soc_s6/, which test-sim writes. The cycle counts of both are
reported. Writes build/xsim_soc_ddr3/soc_ddr3_check.json.

Memory that was never written reads back as X from Micron's DDR3 model (the
SDR model returns zeros). The programs fetch some of it speculatively, past
the end of code they copied to SDRAM, and discard it. The checker's model
treats unwritten memory as zero, so X digits in response data are counted,
reported and read as 0; the retirement comparison with the SDR run shows
they changed no result.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import read_hex
from model.cache_check import compare_cached
from scripts.check_soc_s6 import retirements


def cycles(log):
    m = re.search(r"SOC_(?:S6|DDR3)_TEST_PASS cycles=(\d+)", Path(log).read_text()) if Path(log).exists() else None
    return int(m[1]) if m else None


def main():
    out = ROOT / "build/xsim_soc_ddr3"
    sdr = ROOT / "build/xsim_soc_s6"
    runs = json.loads((ROOT / "config/soc_ddr3_runs.json").read_text())
    results = []
    for run in runs:
        name = run["name"]
        raw = out / f"{name}.csv"
        text = raw.read_text()
        unknown = sum(1 for line in text.splitlines() if line.startswith(("IR,", "R,")) and "x" in line)
        trace = out / f"{name}.x0.csv"
        trace.write_text("\n".join(line.replace("x", "0") if line.startswith(("IR,", "R,")) else line
                                   for line in text.splitlines()) + "\n")
        for dump in (".mem", ".sdram"):   # the final on-chip RAM and DDR3 contents
            Path(str(trace) + dump).write_text(Path(str(raw) + dump).read_text())
        program = read_hex(ROOT / run["image"])
        count, model, checker, _ = compare_cached(program, trace, run["icache"], run["dcache"], run["cache_en"])
        result = {"run": name, "records": count, "memory_side": {m: vars(c) for m, c in checker.observed.items()},
                  "ddr3_cycles": cycles(out / f"{name}.log"), "sdr_cycles": cycles(sdr / f"{name}.log"),
                  "responses_with_unknown_data": unknown}
        plain = checker.interrupts == 0 and checker.mmio_accesses == 0
        if plain and (sdr / f"{name}.csv").exists():
            if retirements(trace) != retirements(sdr / f"{name}.csv"):
                raise AssertionError(f"{name}: retirements differ from the SDR SDRAM run")
            result["same_retirements_as_sdr"] = True
        results.append(result)
        print(f"PASS DDR3 SoC {name}: {count} records, D {vars(checker.observed['D'])}, I {vars(checker.observed['I'])}, "
              f"cycles DDR3 {result['ddr3_cycles']} SDR {result['sdr_cycles']}, {unknown} responses with X data"
              + (", same retirements as SDR" if result.get("same_retirements_as_sdr") else ""))
    (out / "soc_ddr3_check.json").write_text(json.dumps({"runs": results}, indent=2) + "\n")
    print(f"DDR3_SOC_CHECK_PASS {len(results)} runs")


if __name__ == "__main__":
    main()
