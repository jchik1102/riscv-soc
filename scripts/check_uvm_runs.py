import argparse
import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.reference import read_hex
from model.pipeline_check import compare_pipeline
from collections import Counter

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--directory", default="build/uvm_pipeline")
    p.add_argument("--spike", action="store_true", help="also compare generated programs with Spike")
    args = p.parse_args()
    results, coverage = [], Counter()
    traces = sorted((ROOT / args.directory).glob("*/*.csv"))
    if not traces: raise SystemExit("No UVM transcripts found")
    for trace in traces:
        image = read_hex(trace.with_suffix(".hex"))
        count, model, checker = compare_pipeline(image, trace)
        coverage.update(model.coverage)
        resets = trace.read_text().count("RESET")
        results.append({"trace": str(trace.relative_to(ROOT)), "records": count, "fetches": checker.fetches,
                        "data_accesses": checker.accesses, "reset_markers": resets})
        print(f"PASS UVM/Python: {trace.relative_to(ROOT)}: {count} records, {checker.accesses} data accesses")
    if args.spike:
        from scripts.spike_compare import run_case
        spike = Path.home() / ".local/bin/spike"
        programs = ROOT / "build/programs"
        for trace in traces:
            if not trace.stem.startswith("random_"): continue
            name = f"uvm_{trace.parent.name}_{trace.stem}"
            image = read_hex(trace.with_suffix(".hex"))
            (programs / f"{name}.bin").write_bytes(bytes(image))
            result = run_case(name, spike)
            print(f"PASS Spike/Python: {name}, {result['register_commits']} commits")
    out = ROOT / "build/uvm_python_check.json"
    out.write_text(json.dumps({"transcripts": results, "instruction_coverage": coverage}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} UVM transcripts, {sum(r['records'] for r in results)} records re-checked by Python")

if __name__ == "__main__":
    main()
