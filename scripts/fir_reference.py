import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TAPS, SAMPLES, SEED = 16, 128, 2026
MASK64 = (1 << 64) - 1

def data():
    rng = random.Random(SEED)
    coeff = [rng.randint(-9000, 16000) for _ in range(TAPS)]
    coeff[0], coeff[1] = 32767, -32768
    samples = [rng.randint(-32768, 32767) for _ in range(SAMPLES)]
    samples[40:48] = [32767] * 8
    samples[80:88] = [-32768] * 8
    samples[100:104] = [0, 1, -1, 0]
    return coeff, samples

def fir(coeff, samples):
    out = []
    for n in range(len(samples)):
        acc = 0
        for k, h in enumerate(coeff):
            if n - k >= 0:
                product = h * samples[n - k]
                assert -(1 << 31) <= product < (1 << 31)
                acc += product
        assert -(1 << 63) <= acc < (1 << 63)
        value = (acc + (1 << 14)) >> 15
        out.append(max(-32768, min(32767, value)))
    return out

def checksum(outputs):
    return sum((n + 1) * (y & 0xffff) for n, y in enumerate(outputs)) & MASK64

def main():
    coeff, samples = data()
    outputs = fir(coeff, samples)
    total = checksum(outputs)
    saturated = sum(y in (-32768, 32767) for y in outputs)
    assert saturated > 0, "contract requires saturation to be exercised"
    def array(name, values):
        body = ",\n".join("  " + ", ".join(str(v) for v in values[i:i + 12]) for i in range(0, len(values), 12))
        return f"static const short {name}[{len(values)}] = {{\n{body}\n}};\n"
    header = ("#ifndef FIR_DATA_H\n#define FIR_DATA_H\n#define FIR_TAPS %d\n#define FIR_SAMPLES %d\n"
              "#define FIR_EXPECTED_CHECKSUM 0x%016xUL\n" % (TAPS, SAMPLES, total)
              + array("fir_coeff", coeff) + array("fir_input", samples) + "#endif\n")
    (ROOT / "sw/fir_data.h").write_text(header)
    out = ROOT / "build/firmware"
    out.mkdir(parents=True, exist_ok=True)
    (out / "fir_expected.json").write_text(json.dumps(
        {"taps": TAPS, "samples": SAMPLES, "seed": SEED, "checksum": total, "saturated_outputs": saturated,
         "coefficients": coeff, "input": samples, "outputs": outputs}, indent=1) + "\n")
    print(f"FIR reference: {SAMPLES} outputs, {saturated} saturated, checksum 0x{total:016x}")

if __name__ == "__main__":
    main()
