import json
import random
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.rv64_programs import cases as rv64_cases, s5_cases, s6_cases, s6_soc_cases, s7_cases, s7_soc_cases, s8_soc_cases
from scripts.build_firmware import build
from scripts import fir_reference

ROOT = Path(__file__).resolve().parents[1]

def addi(rd, rs1, imm):
    assert -2048 <= imm <= 2047
    return ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13

def add(rd, rs1, rs2):
    return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33

def generate():
    out = ROOT / "build/programs"
    out.mkdir(parents=True, exist_ok=True)
    cases = {"first": [addi(1, 0, 5), addi(2, 0, 7), add(3, 1, 2)],
             "edges": [addi(1, 0, -1), addi(2, 1, -2048), addi(3, 2, 2047),
                       addi(0, 0, 123), add(4, 0, 3), add(5, 1, 1), add(1, 1, 4),
                       addi(31, 0, -2048), add(31, 31, 31)]}
    cases["overflow"] = [addi(1, 0, 1)] + [add(1, 1, 1)] * 63 + [
        addi(2, 1, -1), addi(3, 0, -1), add(4, 1, 1), add(5, 2, 3), add(6, 3, 3)]
    cases["reset_state"] = [add(4, 1, 2), addi(1, 0, 5), addi(2, 0, 7),
                             add(3, 1, 2), addi(1, 1, -1), add(5, 4, 1)]
    for name, instruction in {"m_word_reserved":0x0200103b, "compressed":0x00000001}.items():
        cases[f"reject_{name}"] = cases["first"] + [instruction]
    for name, instruction in {"sub":0x40000033,"addiw":0x0010809b,"shift":0x00109093,
                              "ecall":0x00000073,"ebreak":0x00100073,"fence":0x0000000f,
                              "mul":0x02000033}.items():
        cases[f"promoted_{name}"] = cases["first"] + [instruction]
    for seed in (1, 7, 42):
        rng = random.Random(seed)
        words = [addi(i, 0, rng.randint(-2048, 2047)) for i in range(1, 32)]
        for _ in range(200):
            rd, rs1, rs2 = (rng.randrange(32) for _ in range(3))
            words.append(add(rd, rs1, rs2) if rng.randrange(2) else addi(rd, rs1, rng.randint(-2048, 2047)))
        cases[f"random_{seed}"] = words
    cases.update(rv64_cases())
    for name, words in cases.items():
        data = b"".join(w.to_bytes(4, "little") for w in words + [0])
        (out / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in data) + "\n")
        (out / f"{name}.bin").write_bytes(data)
    build('first')
    fir_reference.main()
    build('s4_board')
    build('fir_hw')
    build('s4_demo')
    for firmware in ('array', 'muldiv', 'fir'):
        data = build(firmware)
        (out / f'asm_{firmware}.bin').write_bytes(data)
        (out / f'asm_{firmware}.hex').write_text('@00000000\n' + '\n'.join(f'{b:02x}' for b in data) + '\n')
        cases[f'asm_{firmware}'] = []
    (out / "manifest.json").write_text(json.dumps(list(cases), indent=2) + "\n")
    s5 = s5_cases()
    for name, words in s5.items():
        data = b"".join(w.to_bytes(4, "little") for w in words + [0])
        (out / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in data) + "\n")
        (out / f"{name}.bin").write_bytes(data)
    (out / "manifest_s5.json").write_text(json.dumps(list(s5), indent=2) + "\n")
    for manifest, programs in (("manifest_s6.json", s6_cases()), ("manifest_s6_soc.json", s6_soc_cases()),
                               ("manifest_s7.json", s7_cases()), ("manifest_s7_soc.json", s7_soc_cases()),
                               ("manifest_s8_soc.json", s8_soc_cases())):
        for name, words in programs.items():
            data = b"".join(w.to_bytes(4, "little") for w in words + [0])
            (out / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in data) + "\n")
            (out / f"{name}.bin").write_bytes(data)
        (out / manifest).write_text(json.dumps(list(programs), indent=2) + "\n")
    build('s5_sdram')
    build('s5_board')
    build('s6_bench')
    build('s6_board')
    build('s7_bench')
    build('s7_board')
    build('s8_bench')
    build('s8_board')
    from scripts.check_s8_demo import expected_report as s8_report
    checksum = s8_report("s8_board")["checksum"]
    (ROOT / "build/firmware/s8_expected.json").write_text(json.dumps(
        {"checksum": checksum, "checksum_hex": f"{checksum:016x}", "checksum_31": checksum & 0x7fffffff}, indent=2) + "\n")
    from scripts.check_s7_bench import expected_report
    checksum = expected_report("s7_board")["checksum"]
    (ROOT / "build/firmware/s7_expected.json").write_text(json.dumps(
        {"checksum": checksum, "checksum_hex": f"{checksum:016x}", "checksum_31": checksum & 0x7fffffff}, indent=2) + "\n")
    from scripts.check_s6_bench import expected_results
    checksum = expected_results("s6_board")[1]
    (ROOT / "build/firmware/s6_expected.json").write_text(json.dumps(
        {"checksum": checksum, "checksum_hex": f"{checksum:016x}", "checksum_31": checksum & 0x7fffffff}, indent=2) + "\n")
    from scripts.check_soc_s5 import workload_checksum
    checksum = workload_checksum()
    (ROOT / "build/firmware/s5_expected.json").write_text(json.dumps(
        {"checksum": checksum, "checksum_hex": f"{checksum:016x}", "checksum_31": checksum & 0x7fffffff}, indent=2) + "\n")

if __name__ == "__main__":
    generate()
