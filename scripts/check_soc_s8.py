import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import MAP, read_hex
from model.cache_check import compare_cached
from model.accel_check import AccelChecker
from scripts.check_s8_demo import check_demo, windows_from_marks

ICACHE, DCACHE = MAP["caches"]["icache_bytes"], MAP["caches"]["dcache_bytes"]
COUNTERS = MAP["devices"]["counters"]["base"]

def word(model, offset):
    return int.from_bytes(model.mem[offset:offset + 8], "little")

def check_random(name, model, checker, resets):
    mix = {"accel_starts": checker.accel.starts, "accel_completions": checker.accel.completions,
           "accel_error_responses": checker.accel_errors, "external_interrupts": checker.external_interrupts,
           "timer_interrupts": checker.interrupts - checker.external_interrupts, "handled_traps": checker.handled_traps,
           "d_fills": checker.observed["D"].fills, "i_fills": checker.observed["I"].fills, "fence_i": checker.fence_i}
    missing = [key for key, value in mix.items() if value == 0]
    if missing: raise AssertionError(f"{name}: the random mix did not exercise {missing}")
    if resets == 0:
        logged = {"handled_traps": word(model, 0x4008), "external_interrupts": word(model, 0x4010),
                  "timer_interrupts": word(model, 0x4018)}
        for key, value in logged.items():
            if value != mix[key]: raise AssertionError(f"{name}: handler counted {key} {value}, checker {mix[key]}")
    return mix

def main():
    out = ROOT / "build/xsim_soc_s8"
    runs = json.loads((ROOT / "config/soc_s8_runs.json").read_text())
    only = set(sys.argv[1:])
    results = []
    for run in runs:
        name = run["name"]
        if only and name not in only: continue
        base = run.get("program", name)
        trace = out / f"{name}.csv"
        program = read_hex(ROOT / run["image"])
        checker = AccelChecker(program, ICACHE, DCACHE, 3, run["accel_n"], bool(run["accel_parallel"]))
        marks = []
        def watch(address, data):
            if address != COUNTERS: return False
            marks.append(data)
            return True
        count, model, checker, snapshots = compare_cached(program, trace, ICACHE, DCACHE, 3, watch_store=watch, checker=checker)
        resets = trace.read_text().count("RESET\n")
        if (run.get("reset_at") is not None) != (resets == 1) or resets > 1:
            raise AssertionError(f"{name}: {resets} CPU resets in the transcript")
        if checker.accel.starts == 0: raise AssertionError(f"{name}: the accelerator never started")
        result = {"run": name, "records": count, "accel_n": run["accel_n"], "accel_parallel": run["accel_parallel"],
                  "resets": resets, "interrupts": checker.interrupts, "external_interrupts": checker.external_interrupts,
                  "accel_accesses": checker.accel_accesses, "accel_error_responses": checker.accel_errors,
                  "accel_loads_checked": checker.accel_checked_loads, "accel_starts": checker.accel.starts,
                  "accel_completions": checker.accel.completions, "irq_records": checker.irq_records,
                  "memory_side": {m: vars(c) for m, c in checker.observed.items()}}
        if base == "s8_demo":
            windows = windows_from_marks(marks, snapshots) if resets == 0 else None
            result.update(check_demo(name, model, checker, run, "s8_bench", windows))
        elif base.startswith("s8_random_"):
            result["mix"] = check_random(name, model, checker, resets)
        results.append(result)
        print(f"PASS S8 SoC {name}: {count} records, accelerator {checker.accel_accesses} accesses "
              f"({checker.accel_errors} errors, {checker.accel_checked_loads} loads checked), "
              f"{checker.accel.starts} starts, {checker.accel.completions} completions, "
              f"{checker.external_interrupts} external / {checker.interrupts} interrupts, "
              f"{checker.handled_traps} handled traps, {resets} resets")
    if not results: raise AssertionError(f"No S8 SoC run matched {sorted(only)}")
    (out / "s8_soc_check.json").write_text(json.dumps({"runs": results}, indent=2) + "\n")

if __name__ == "__main__":
    main()
