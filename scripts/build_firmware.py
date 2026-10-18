import re
import subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
MARCH = "rv64im"
PROGRAMS = {"first": ["sw/first.S"], "array": ["sw/array.S"], "muldiv": ["sw/muldiv.S", "sw/m_kernel.c"],
            "fir": ["sw/fir_start.S", "sw/fir.c"], "fir_hw": ["sw/fir_start.S", "sw/fir_hw.c"],
            "s4_demo": ["sw/s4_start.S", "sw/s4_demo.c"], "s4_board": ["sw/s4_start.S", "sw/s4_demo.c"],
            "s5_sdram": ["sw/s4_start.S", "sw/s5_sdram.c"], "s5_board": ["sw/s4_start.S", "sw/s5_sdram.c"],
            "s6_bench": ["sw/s4_start.S", "sw/s6_bench.c"], "s6_board": ["sw/s4_start.S", "sw/s6_bench.c"],
            "s7_bench": ["sw/s4_start.S", "sw/s7_bench.c"], "s7_board": ["sw/s4_start.S", "sw/s7_bench.c"],
            "s8_bench": ["sw/s4_start.S", "sw/s8_demo.c"], "s8_board": ["sw/s4_start.S", "sw/s8_demo.c"]}
ZICSR = {"fir_hw": [], "s4_demo": [], "s4_board": ["-DTICK_PERIOD=5000000UL", "-DTICKS=50UL", "-DUART_DIV=434UL"],
         "s5_sdram": [], "s5_board": ["-DTEST_BYTES=0x4000000UL", "-DTICK_PERIOD=5000000UL", "-DRUN_COUNTER"],
         "s6_bench": [], "s6_board": ["-DTICK_PERIOD=50000UL", "-DSMALL_WORDS=256UL", "-DBIG_WORDS=4096UL", "-DROUNDS=8UL"],
         "s7_bench": [], "s7_board": ["-DTICK_PERIOD=50000UL", "-DRANDOM_CASES=58UL"],
         "s8_bench": [], "s8_board": ["-DTICK_PERIOD=50000UL", "-DRANDOM_CASES=58UL"]}
ZIFENCEI = {"s6_bench", "s6_board"}
LINKER = {"s6_bench": "sw/link_s6.ld", "s6_board": "sw/link_s6.ld"}
M_MNEMONICS = {"mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
               "mulw", "divw", "divuw", "remw", "remuw"}

def build(name):
    out = ROOT / "build/firmware"
    out.mkdir(parents=True, exist_ok=True)
    elf = out / f"{name}.elf"
    march, defines = (MARCH + "_zicsr", ZICSR[name]) if name in ZICSR else (MARCH, [])
    if name in ZIFENCEI: march += "_zifencei"
    subprocess.run(["riscv64-unknown-elf-gcc", f"-march={march}", "-mabi=lp64", "-mcmodel=medany", "-O2", *defines,
                    "-ffreestanding", "-fno-builtin", "-nostdlib", "-nostartfiles", "-Wl,--no-relax",
                    "-T", LINKER.get(name, "sw/link.ld"), *PROGRAMS[name], "-o", str(elf)], cwd=ROOT, check=True, timeout=60)
    for tool, args, report in [("objdump", ["-d", str(elf)], f"{name}.dis"), ("readelf", ["-h", "-A", str(elf)], f"{name}.attributes")]:
        run = subprocess.run([f"riscv64-unknown-elf-{tool}", *args], capture_output=True, text=True, check=True, timeout=30)
        (out / report).write_text(run.stdout)
    attributes = (out / f"{name}.attributes").read_text()
    if "rv64i2p1_m2p0" not in attributes:
        raise AssertionError(f"{name}: ELF does not record the rv64im architecture")
    binary = out / f"{name}.bin"
    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf), str(binary)], check=True, timeout=30)
    if name == 'first' and binary.read_bytes() != bytes.fromhex("9300500013017000b381200000000000"):
        raise AssertionError("Compiler emitted unexpected instructions")
    if name == 'muldiv':
        text = (out / f"{name}.dis").read_text()
        used = set(re.findall(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+(\w+)", text, re.M))
        missing = M_MNEMONICS - used
        if missing: raise AssertionError(f"muldiv image lacks M instructions: {sorted(missing)}")
        if re.search(r"<__\w+>", text): raise AssertionError("muldiv image calls a runtime helper")
    if name.startswith('s5_'):
        text = (out / f"{name}.dis").read_text()
        used = set(re.findall(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+(\w+)", text, re.M))
        missing = {"lb", "lbu", "lh", "lhu", "lw", "lwu", "ld", "sb", "sh", "sw", "sd", "mul"} - used
        if missing: raise AssertionError(f"{name} image lacks expected SDRAM access instructions: {sorted(missing)}")
        if re.search(r"\bjal\b.*<__\w+>", text): raise AssertionError(f"{name} image calls a runtime helper")
    if name.startswith('s6_'):
        text = (out / f"{name}.dis").read_text()
        body = re.search(r"<kernel>:\n(.*?)(?:\n\n|\Z)", text, re.S)
        if not body: raise AssertionError(f"{name}: kernel not found")
        if re.search(r"\s(auipc|jal)\s", body.group(1)): raise AssertionError(f"{name}: kernel is not position independent")
        if not re.search(r"fence\.i", text): raise AssertionError(f"{name}: no FENCE.I")
    if name.startswith(('s7_', 's8_')):
        text = (out / f"{name}.dis").read_text()
        if not re.search(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+mulw?\s", text, re.M):
            raise AssertionError(f"{name} image lacks a hardware multiply")
        if re.search(r"\bjal\b.*<__\w+>", text): raise AssertionError(f"{name} image calls a runtime helper")
    if name == 'fir':
        text = (out / f"{name}.dis").read_text()
        if not re.search(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+mulw?\s", text, re.M):
            raise AssertionError("fir image lacks a hardware multiply")
        if re.search(r"\bjal\b.*<__\w+>", text): raise AssertionError("fir image calls a runtime helper")
    (out / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in binary.read_bytes()) + "\n")
    data = binary.read_bytes()
    words = 1 << max(0, ((len(data) + 7) // 8 - 1).bit_length())
    padded = data + bytes(8 * words - len(data))
    (out / f"{name}_words.hex").write_text("".join(
        f"{int.from_bytes(padded[i:i+8], 'little'):016x}\n" for i in range(0, len(padded), 8)))
    print(f"BUILT: {name}, GCC {MARCH.upper()}/LP64 ELF, {len(binary.read_bytes())} bytes")
    return binary.read_bytes()

def main():
    for name in PROGRAMS: build(name)

if __name__ == "__main__":
    main()
