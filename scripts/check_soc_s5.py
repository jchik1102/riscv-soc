import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.rv64i import read_hex
from model.pipeline_check import compare_pipeline

MASK = (1 << 64) - 1
MAGIC = 0x5335534452414D00
TEST_BYTES = 0x4000
WORK_WORDS = 512

def workload_checksum():
    x, a = 12345, []
    for _ in range(WORK_WORDS):
        x = (x * 6364136223846793005 + 1442695040888963407) & MASK
        a.append(x)
    running, b = 0, []
    for i in range(WORK_WORDS):
        running = (running + a[i] * (i | 1)) & MASK
        b.append(running)
    block = bytearray((i * 7 + 3) & 255 for i in range(256))
    block.reverse()
    total = 0
    for value in b:
        total = (((total << 5) | (total >> 59)) & MASK) ^ value
    for i in range(0, 256, 8):
        total = (total + int.from_bytes(block[i:i + 8], "little")) & MASK
    return total

def expected_words():
    probes, walking, beats, subword = 12, 64, 3, 6
    return probes + walking + beats + subword + 3 * TEST_BYTES // 8

def check_firmware(name, model, checker):
    word = lambda offset: int.from_bytes(model.mem[offset:offset + 8], "little")
    magic, checksum, status, errors, ticks, words, first_bad, phase, runs = (word(0x8000 + 8 * i) for i in range(9))
    expected = (MAGIC, workload_checksum(), 1, 0, expected_words(), 0, 6, 0)
    actual = (magic, checksum, status, errors, words, first_bad, phase, runs)
    if actual != expected:
        raise AssertionError(f"{name}: report {actual} != expected {expected}")
    if ticks < 1 or ticks != checker.interrupts_since_reset:
        raise AssertionError(f"{name}: ticks {ticks}, interrupt records since reset {checker.interrupts_since_reset}")
    return {"checksum": hex(checksum), "words_verified": words, "ticks": ticks}

def main():
    out = ROOT / "build/xsim_soc_s5"
    runs = json.loads((ROOT / "build/programs/manifest_s5.json").read_text())
    images = {name: ROOT / f"build/programs/{name}.hex" for name in runs}
    images.update({"s5_sdram_fw": ROOT / "build/firmware/s5_sdram.hex",
                   "s5_random_5_reset": ROOT / "build/programs/s5_random_5.hex",
                   "s5_sdram_fw_reset": ROOT / "build/firmware/s5_sdram.hex"})
    results = []
    for name, image_path in images.items():
        trace = out / f"{name}.csv"
        count, model, checker = compare_pipeline(read_hex(image_path), trace, sdram=True)
        resets = trace.read_text().count("RESET\n")
        if name.endswith("_reset") and resets != 1:
            raise AssertionError(f"{name}: expected one CPU reset in the transcript, found {resets}")
        result = {"run": name, "records": count, "sdram_accesses": checker.sdram_accesses,
                  "sdram_bytes_written": sum(1 for _ in checker.phys_sdram.items()),
                  "interrupts": checker.interrupts, "resets": resets}
        if name.startswith("s5_sdram_fw"):
            result.update(check_firmware(name, model, checker))
        results.append(result)
        print(f"PASS S5 SoC {name}: {count} records, {checker.sdram_accesses} SDRAM accesses, "
              f"{result['sdram_bytes_written']} SDRAM bytes checked, {checker.interrupts} interrupts, {resets} resets")
    (out / "s5_soc_check.json").write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
