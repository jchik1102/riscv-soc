import argparse
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64m import MASK64, WORD_NAMES, m_result

EDGE64 = [0, 1, 2, 3, 7, MASK64, MASK64 - 1, MASK64 - 6, 1 << 63, (1 << 63) - 1, (1 << 63) + 1,
          0x7fffffff, 0x80000000, 0xffffffff, 1 << 32, 0xffffffff7fffffff, 0x00000000fffffffe,
          0x5555555555555555, 0xaaaaaaaaaaaaaaaa, 0x123456789abcdef0]
EDGE32 = [0, 1, 2, 7, 0xffffffff, 0xfffffffe, 0xfffffff9, 0x80000000, 0x7fffffff, 0x80000001, 0x00010000]
UPPER = [0, 0xffffffff, 0xa5a5a5a5]
OPS = [(f3, 0) for f3 in range(8)] + [(f3, 1) for f3 in sorted(WORD_NAMES)]

def random_operand(rng, word):
    bits = 32 if word else 64
    length = rng.randint(0, bits)
    value = rng.getrandbits(length) if length else 0
    if rng.randrange(2):
        value = (-value) & ((1 << bits) - 1)
    if word:
        value |= rng.getrandbits(32) << 32
    return value

def vectors(seed=2024, random_count=160):
    rng = random.Random(seed)
    result = []
    for f3, word in OPS:
        if word:
            edges = [(upper << 32) | low for low in EDGE32 for upper in UPPER]
        else:
            edges = EDGE64
        for a in edges:
            for b in edges:
                result.append((f3, word, a, b))
        for _ in range(random_count):
            result.append((f3, word, random_operand(rng, word), random_operand(rng, word)))
    rng.shuffle(result)
    return [(f3, word, a, b, m_result(f3, word, a, b)) for f3, word, a, b in result]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=2024)
    parser.add_argument("--output", default=str(ROOT / "build/muldiv/vectors.txt"))
    args = parser.parse_args()
    rows = vectors(args.seed)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(f"{f3:x} {word:x} {a:016x} {b:016x} {e:016x}\n" for f3, word, a, b, e in rows))
    print(f"VECTORS: {len(rows)} M operations, seed {args.seed}, {out}")

if __name__ == "__main__":
    main()
