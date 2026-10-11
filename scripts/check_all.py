import argparse
import json
import re
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.reference import BASE_NAMES, M_NAMES, ZIFENCEI_NAMES, MASK, compare, read_hex
from model.pipeline_check import compare_pipeline
from collections import Counter

REQUIRED_EVENTS = {
    "multicycle": ("addi", "add", "negative", "x0", "dependency", "reset", "request_stalls", "response_stalls",
                   "m_ops", "m_x0", "m_dependency", "arith_wait_cycles", "arith_reset"),
    "pipeline": ("reset", "request_stalls", "response_stalls", "fetch_request_stalls", "fwd_mem", "fwd_wb",
                 "id_bypass", "store_data_fwd", "branch_fwd", "jalr_fwd", "load_use", "redirects", "flushed_id",
                 "flushed_ex_trap", "mem_flush", "m_ops", "m_x0", "m_back_to_back", "m_with_mem_wait",
                 "older_retire_during_m", "m_kills", "arith_reset", "arith_wait_cycles", "fetch_wait", "mem_wait"),
}

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--directory", default=None)
    p.add_argument("--core", choices=sorted(REQUIRED_EVENTS), default="multicycle")
    args = p.parse_args()
    pipeline = args.core == "pipeline"
    if args.directory is None: args.directory = "build/xsim_pipe" if pipeline else "build/xsim_core"
    matrix = "config/regression_pipeline.json" if pipeline else "config/regression.json"
    results = []
    instruction_coverage = Counter()
    groups = json.loads((ROOT / matrix).read_text())
    all_cases = json.loads((ROOT / "build/programs/manifest.json").read_text())
    traces = []
    for group in groups:
        cases = all_cases if group["cases"] == "all" else group["cases"]
        for reset in group["reset_cycles"]:
            for case in cases:
                suffix = f"_m{group['reset_mode']}" if group.get("reset_mode", 0) else ""
                if group.get("irq_rate", 0): suffix += f"_i{group['irq_rate']}"
                traces.append(ROOT / args.directory / f"{case}_s{group['seed']}_d{group['max_delay']}_r{reset}{suffix}.csv")
    if not traces:
        raise SystemExit("No traces found")
    for trace in traces:
        name = trace.stem.rsplit("_s", 1)[0]
        image = read_hex(ROOT / "build/programs" / f"{name}.hex")
        if pipeline: count, model, _ = compare_pipeline(image, trace)
        else: count, model = compare(image, trace, require_bus=True)
        if name == 'first': assert model.regs[:4] == [0,5,7,12]
        if name == 'array_loop': assert model.regs[5] == 136
        if name == 'asm_array': assert model.regs[10:13] == [MASK-7,0xfffffff8,MASK-7]
        if name == 'control': assert model.regs[7] == 24 and model.regs[10] == 99
        if name == 'm_mixed':
            r = model.regs
            assert (r[1], r[6], r[11], r[13], r[14], r[15], r[9]) == (3628800, 21, 45, MASK-2, MASK, MASK-1, 2025)
            assert (r[18], r[19], r[23], r[26], r[27]) == (MASK, 3628800, 3628799, 3, 1)
        if name == 'asm_muldiv':
            start = model.regs[8] - 0x80000000
            stored = [int.from_bytes(model.mem[start+8*i:start+8*i+8], 'little') for i in range(15)]
            assert stored == [MASK-13, 1<<62, MASK, MASK-1, 1<<63, 0x7ffffffffffffffc, MASK, 1, MASK,
                              MASK-104, MASK-2, 0x7ffffffc, 15, 1, 571762160]
        if name == 'promoted_mul': assert model.regs[:4] == [0,5,7,12]
        if name == 'pipe_forward':
            r = model.regs
            assert r[2:8] == [10, 15, 20, 10, 5, 5] and (r[9], r[11], r[13], r[15], r[17]) == (77, 78, 154, 154, 8)
            assert (r[24], r[26], r[27], r[28], r[29], r[30], r[31]) == (5, 152, 50, 2500, 500, 2500, 0)
            assert bytes(model.mem[0x4018:0x4038]) == bytes(32)
        if name == 'asm_fir':
            fir = json.loads((ROOT / 'build/firmware/fir_expected.json').read_text())
            word = lambda offset: int.from_bytes(model.mem[offset:offset+8], 'little')
            assert (word(0x8000), word(0x8008), word(0x8010)) == (0x4649523151313500, fir['checksum'], 1)
            symbols = (ROOT / 'build/firmware/fir.dis').read_text()
            start = int(re.search(r'([0-9a-f]+) <fir_output>', symbols)[1], 16) - 0x80000000
            outputs = [int.from_bytes(model.mem[start+2*i:start+2*i+2], 'little', signed=True) for i in range(fir['samples'])]
            assert outputs == fir['outputs']
        if name == 'pipe_redirect': assert [model.regs[i] for i in (1,2,3,5,6,7)] == [0,0,3,0,4,4]
        if name in ('pipe_trap_shadow', 'pipe_misaligned_shadow', 'pipe_kill_load', 'pipe_kill_store'):
            first = 1 if name == 'pipe_trap_shadow' else 0
            assert int.from_bytes(model.mem[0x4000:0x4008], 'little') == first and bytes(model.mem[0x4008:0x4010]) == bytes(8)
        if name == 'reset_store':
            expected = 2 if trace.stem.endswith('_m1') else 1
            assert int.from_bytes(model.mem[0x4000:0x4008],'little') == expected
        instruction_coverage.update(model.coverage)
        log_path = trace.with_suffix(".log")
        log = log_path.read_text(errors="replace")
        if "CORE_TB_DONE" not in log:
            raise AssertionError(f"Missing completion marker in {log_path}")
        coverage = next((line for line in log.splitlines() if line.startswith("EXECUTED_COVERAGE ")), None)
        if coverage is None:
            raise AssertionError(f"Missing executed-event coverage in {log_path}")
        bins = {k: int(v) for k, v in (entry.split("=") for entry in coverage.split()[1:])}
        results.append({"trace": str(trace.relative_to(ROOT)), "records": count, "result": "PASS", "executed_events": bins})
        print(f"PASS {trace.name}: {count} records")
    for required in REQUIRED_EVENTS[args.core]:
        if not any(r["executed_events"][required] for r in results):
            raise AssertionError(f"Uncovered required executed event: {required}")
    required = BASE_NAMES | M_NAMES | ZIFENCEI_NAMES | {"M_divide_by_zero", "M_signed_overflow"} | {f"{b}_{outcome}" for b in ("BEQ","BNE","BLT","BGE","BLTU","BGEU") for outcome in ("taken","not_taken")}
    required |= {f"cause_{c}" for c in (0,1,2,3,4,5,6,7,11)}
    if pipeline:
        from model.rv64s4 import ZICSR_NAMES
        required |= ZICSR_NAMES | {"trap_handled", "interrupt_3", "interrupt_7", "interrupt_11"}
    missing = sorted(required - instruction_coverage.keys())
    if missing: raise AssertionError(f"Missing executed instruction/exception coverage: {missing}")
    suffix = "_pipeline" if pipeline else ""
    (ROOT / f"build/trace_results{suffix}.json").write_text(json.dumps(results, indent=2) + "\n")
    (ROOT / f"build/instruction_coverage{suffix}.json").write_text(json.dumps(instruction_coverage, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} traces, {sum(r['records'] for r in results)} records")

if __name__ == "__main__":
    main()
