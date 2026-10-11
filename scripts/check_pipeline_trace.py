import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model.reference import read_hex
from model.pipeline_check import compare_pipeline

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("traces", nargs="+")
    args = p.parse_args()
    for trace in args.traces:
        count, model, checker = compare_pipeline(read_hex(args.image), trace)
        print(f"PASS {trace}: {count} records, {checker.fetches} fetches, {checker.accesses} data accesses")
