import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import MAP, read_hex
from model.cache_check import compare_cached
from model.accel_check import AccelChecker

TAGS = ("T,", "IQ,", "IR,", "Q,", "R,", "SQ,", "FI", "X,")
ICACHE, DCACHE = MAP["caches"]["icache_bytes"], MAP["caches"]["dcache_bytes"]

def retirements(path):
    return [line for line in Path(path).read_text().splitlines()[1:] if line != "RESET" and not line.startswith(TAGS)]

def word(model, offset):
    return int.from_bytes(model.mem[offset:offset + 8], "little")

def check_directed(base, model, checker):
    if base == "s7_accel":
        if checker.handled_traps < 6: raise AssertionError(f"s7_accel: only {checker.handled_traps} handled traps")
        log = [(word(model, 0x5000 + 16 * i), word(model, 0x5008 + 16 * i)) for i in range(checker.handled_traps)]
        if sum(cause in (5, 7) for cause, _ in log) != checker.handled_traps:
            raise AssertionError(f"s7_accel: trap causes {log}")
        return {"handled_traps": checker.handled_traps, "accel_errors": checker.accel_errors}
    if base == "s7_irq":
        if checker.external_interrupts != 4: raise AssertionError(f"s7_irq: {checker.external_interrupts} external interrupts")
        accel_bit = 1 << MAP["interrupts"]["accelerator"]
        pending, active, count = word(model, 0x4100), word(model, 0x4108), word(model, 0x4110)
        if not pending & accel_bit or active & accel_bit or count != 1:
            raise AssertionError(f"s7_irq: masked phase PENDING {pending:#x} ACTIVE {active:#x} count {count}")
        if word(model, 0x4120) != 4: raise AssertionError("s7_irq: final count")
        return {"external_interrupts": checker.external_interrupts}
    return {}

def main():
    out = ROOT / "build/xsim_soc_s7"
    runs = json.loads((ROOT / "config/soc_s7_runs.json").read_text())
    only = set(sys.argv[1:])
    results, traces = [], {}
    for run in runs:
        name = run["name"]
        if only and name not in only: continue
        base = run.get("program", name)
        trace = out / f"{name}.csv"
        program = read_hex(ROOT / run["image"])
        checker = AccelChecker(program, ICACHE, DCACHE, 3, run["accel_n"], bool(run["accel_parallel"]))
        count, model, checker, _ = compare_cached(program, trace, ICACHE, DCACHE, 3, checker=checker)
        resets = trace.read_text().count("RESET\n")
        if (run.get("reset_at") is not None) != (resets == 1) or resets > 1:
            raise AssertionError(f"{name}: {resets} CPU resets in the transcript")
        if base.startswith("s7_") and base != "s7_matmul_sw" and checker.accel.starts == 0:
            raise AssertionError(f"{name}: the accelerator never started")
        result = {"run": name, "records": count, "accel_n": run["accel_n"], "accel_parallel": run["accel_parallel"],
                  "resets": resets, "interrupts": checker.interrupts, "external_interrupts": checker.external_interrupts,
                  "accel_accesses": checker.accel_accesses, "accel_error_responses": checker.accel_errors,
                  "accel_loads_checked": checker.accel_checked_loads, "accel_starts": checker.accel.starts,
                  "accel_completions": checker.accel.completions, "irq_records": checker.irq_records,
                  "memory_side": {m: vars(c) for m, c in checker.observed.items()}}
        result.update(check_directed(base, model, checker))
        if base == "s7_bench":
            from scripts.check_s7_bench import check_bench
            result.update(check_bench(name, model, checker, run))
        if base == "s6_bench":
            from scripts.check_s6_bench import check_bench as check_s6
            result.update(check_s6(name, model, checker))
        plain = checker.interrupts == 0 and checker.mmio_accesses == 0 and resets == 0
        traces[name] = (base, retirements(trace), plain)
        results.append(result)
        print(f"PASS S7 SoC {name}: {count} records, accelerator {checker.accel_accesses} accesses "
              f"({checker.accel_errors} errors, {checker.accel_checked_loads} loads checked), "
              f"{checker.accel.starts} starts, {checker.accel.completions} completions, "
              f"{checker.external_interrupts} external / {checker.interrupts} interrupts, {resets} resets")
    compared = []
    for name, (base, rows, plain) in traces.items():
        if not plain or name == base: continue
        reference = ROOT / f"build/xsim_soc_s6/{base}.csv"
        if base in traces and traces[base][2]: ref_rows, label = traces[base][1], base
        elif reference.exists(): ref_rows, label = retirements(reference), f"S6 SoC {base}"
        else: continue
        if rows != ref_rows: raise AssertionError(f"{name}: retirements differ from {label}")
        compared.append({"run": name, "reference": label, "records": len(rows)})
        print(f"PASS same retirements: {name} == {label} ({len(rows)} records)")
    (out / "s7_soc_check.json").write_text(json.dumps({"runs": results, "equivalence": compared}, indent=2) + "\n")

if __name__ == "__main__":
    main()
