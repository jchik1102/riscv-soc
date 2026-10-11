import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import MAP, read_hex
from model.cache_check import compare_cached, COUNTER_NAMES

COUNTERS = MAP["devices"]["counters"]["base"]
SCRATCH = 0x4000
TAGS = ("T,", "IQ,", "IR,", "Q,", "R,", "SQ,", "FI")

def retirements(path):
    rows = []
    for line in Path(path).read_text().splitlines()[1:]:
        if line == "RESET" or line.startswith(TAGS): continue
        rows.append(line)
    return rows

def word(model, offset):
    return int.from_bytes(model.mem[offset:offset + 8], "little")

def check_control(run, model, snapshots):
    if len(snapshots) != 1: raise AssertionError(f"{run['name']}: expected one counter freeze, found {len(snapshots)}")
    expected = [snapshots[0][name] for name in COUNTER_NAMES]
    actual = [word(model, SCRATCH + 8 * i) for i in range(7)]
    if actual != expected:
        raise AssertionError(f"{run['name']}: cache counters {dict(zip(COUNTER_NAMES, actual))} != model {dict(zip(COUNTER_NAMES, expected))}")
    info = (1 << 40) | (MAP["caches"]["line_bytes"] << 32) | (run["dcache"] << 16) | run["icache"]
    if word(model, SCRATCH + 56) != info: raise AssertionError(f"{run['name']}: INFO {word(model, SCRATCH + 56):#x} != {info:#x}")
    if word(model, SCRATCH + 64) != run["cache_en"]: raise AssertionError(f"{run['name']}: CTRL reset value")
    return dict(zip(COUNTER_NAMES, actual))

def main():
    out = ROOT / "build/xsim_soc_s6"
    runs = json.loads((ROOT / "config/soc_s6_runs.json").read_text())
    only = set(sys.argv[1:])
    results, traces = [], {}
    for run in runs:
        name = run["name"]
        if only and name not in only: continue
        trace = out / f"{name}.csv"
        program = read_hex(ROOT / run["image"])
        freeze = (lambda address, data: address == COUNTERS and data == 0) if run.get("program", name) == "s6_control" else None
        count, model, checker, snapshots = compare_cached(program, trace, run["icache"], run["dcache"], run["cache_en"], freeze)
        text = trace.read_text()
        resets = text.count("RESET\n")
        if (run.get("reset_at") is not None) != (resets == 1) or resets > 1:
            raise AssertionError(f"{name}: {resets} CPU resets in the transcript")
        result = {"run": name, "records": count, "icache": run["icache"], "dcache": run["dcache"], "cache_en": run["cache_en"],
                  "resets": resets, "interrupts": checker.interrupts, "fence_i": checker.fence_i,
                  "memory_side": {m: vars(c) for m, c in checker.observed.items()},
                  "events_since_reset": dict(checker.counts)}
        base = run.get("program", name)
        if base == "s6_control": result["counters"] = check_control(run, model, snapshots)
        if base in ("s5_sdram_fw",):
            from scripts.check_soc_s5 import check_firmware
            result.update(check_firmware(name, model, checker))
        if base == "s6_bench":
            from scripts.check_s6_bench import check_bench
            result.update(check_bench(name, model, checker, run))
        traces[name] = (base, retirements(trace), checker.interrupts == 0 and checker.mmio_accesses == 0 and resets == 0)
        results.append(result)
        print(f"PASS S6 SoC {name}: {count} records, D {vars(checker.observed['D'])}, I {vars(checker.observed['I'])}, "
              f"{checker.fence_i} FENCE.I, {checker.interrupts} interrupts, {resets} resets")
    compared = []
    for name, (base, rows, plain) in traces.items():
        if not plain or name == base or base == "s5_fetch_fault": continue
        reference = None
        if base in traces and traces[base][2]: reference, label = traces[base][1], base
        elif (ROOT / f"build/xsim_soc_s5/{base}.csv").exists(): reference, label = retirements(ROOT / f"build/xsim_soc_s5/{base}.csv"), f"S5 SoC {base}"
        if reference is None: continue
        if rows != reference: raise AssertionError(f"{name}: retirements differ from {label}")
        compared.append({"run": name, "reference": label, "records": len(rows)})
        print(f"PASS same retirements: {name} == {label} ({len(rows)} records)")
    (out / "s6_soc_check.json").write_text(json.dumps({"runs": results, "equivalence": compared}, indent=2) + "\n")

if __name__ == "__main__":
    main()
