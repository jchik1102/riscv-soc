import argparse
import json
import re
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import read_hex
from model.pipeline_check import compare_pipeline

TICKS = 6
MAGIC = 0x5334444F4E450000

def checksum():
    work, total = [0] * 32, 0
    for i in range(1, 201):
        work[i & 31] = (work[(i * 7) & 31] + i * i) % 1000003
        total += work[i & 31] // (i % 13 + 1)
    return total & ((1 << 64) - 1)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rx", default="ping")
    args = p.parse_args()
    out = ROOT / "build/xsim_soc_s4"
    image = read_hex(ROOT / "build/firmware/s4_demo.hex")
    count, model, checker = compare_pipeline(image, out / "s4_demo.csv")
    text = (out / "s4_demo.csv.uart").read_text()
    expected = f"S4 start\nticks=0x{TICKS:x} ecalls=0x2 rx={args.rx} sum=0x{checksum():x}\n"
    if text != expected:
        raise AssertionError(f"UART text {text!r} != expected {expected!r}")
    word = lambda offset: int.from_bytes(model.mem[offset:offset + 8], "little")
    report = [word(0x8000 + 8 * i) for i in range(8)]
    magic, ticks, status, ecalls, rx_count, total, cycles, instret = report
    if (magic, ticks, status, ecalls, rx_count, total) != (MAGIC, TICKS, 1, 2, len(args.rx), checksum()):
        raise AssertionError(f"Report block {report}")
    if not cycles > instret > 0: raise AssertionError("mcycle/minstret deltas implausible")
    counters = [word(0x8040 + 8 * i) for i in range(8)]
    if counters[0] != 1 or not counters[1] > counters[2] > 0:
        raise AssertionError(f"Counter block {counters}")
    result = {"records": count, "interrupts": checker.interrupts, "handled_traps": checker.handled_traps,
              "mmio_accesses": checker.mmio_accesses, "uart_text": text, "report": report, "counters": counters}
    (out / "s4_demo_check.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS S4 SoC: {count} records, {checker.interrupts} interrupts, {checker.handled_traps} handled traps, "
          f"{checker.mmio_accesses} MMIO accesses, UART text {text!r}")

if __name__ == "__main__":
    main()
