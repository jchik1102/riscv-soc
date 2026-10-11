import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model.reference import compare, read_hex

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("trace")
    args = p.parse_args()
    count, state = compare(read_hex(args.image), args.trace, require_bus=True)
    print(f"PASS: {count} independently checked trace records; x0={state.regs[0]} x1={state.regs[1]} x2={state.regs[2]} x3={state.regs[3]}")
