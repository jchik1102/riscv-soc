"""Turn generated riscv-dv programs into pipe_tb images and check them on Spike.

For each <out>/asm_test/*.S:
  1. Shrink riscv-dv's fixed 5000-word stacks to 1024 words so the program
     fits the 64 KiB RAM, and insert the halt after the tohost store. riscv-dv ends with
     `write_tohost: sw gp, tohost, t5` and then spins; this core halts only on
     an unhandled trap, so `csrw mtvec, zero; ecall` is added after the store
     (the same ending the ACT macros use). Spike stops at the tohost write.
  2. Compile with the system GCC (13.2) for rv64im, riscv-dv's link script.
  3. Write <name>.bin and <name>.hex (byte per line, scripts/programs.py format).
  4. Spike vs the Python model through scripts/spike_compare.run_case.
Writes <out>/manifest.json and <out>/spike.json, prints one line per program.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT))
from spike_compare import run_case  # noqa: E402

DV = Path.home() / "hwtools/riscv-dv"
RAM_BYTES = 0x10000  # pipe_tb default memory and the model's RAM
MAX_STEPS = 400000   # model steps; matches the pipe_tb watchdog in cycles
STACK_WORDS = 1024
HALT = "                  csrw mtvec, zero\n                  ecall\n"


def main(out):
    out = Path(out)
    images = out / "images"
    images.mkdir(exist_ok=True)
    manifest, spike = [], []
    for asm in sorted((out / "asm_test").glob("*.S")):
        name = asm.stem
        text = asm.read_text()
        patched, n = re.subn(r"(write_tohost:\s*\n\s+sw gp, tohost, t5\n)", r"\1" + HALT, text)
        if n != 1:
            raise SystemExit(f"{name}: expected one write_tohost store, found {n}")
        # riscv-dv hard-codes 5000-word user and kernel stacks (80 KB together),
        # more than the 64 KiB RAM. Sub-programs use at most 16 words each and the
        # trap handler saves 32 registers, so 1024 words (8 KB) per stack is ample.
        patched, n = re.subn(r"(\.section \.(?:user|kernel)_stack[^\n]*\n\.align 2\n\w+_stack_start:\n\.rept )\d+",
                             r"\g<1>" + str(STACK_WORDS - 1), patched)
        if n != 2:
            raise SystemExit(f"{name}: expected user and kernel stack sections, found {n}")
        src = images / f"{name}.S"
        src.write_text(patched)
        elf = images / f"{name}.elf"
        cc = subprocess.run(["riscv64-unknown-elf-gcc", "-static", "-mcmodel=medany", "-fvisibility=hidden",
                             "-nostdlib", "-nostartfiles", "-march=rv64im_zicsr_zifencei", "-mabi=lp64",
                             f"-I{DV}/user_extension", f"-T{DV}/scripts/link.ld", str(src), "-o", str(elf)],
                            capture_output=True, text=True)
        if cc.returncode != 0:
            # pyflow sometimes emits invalid assembly (e.g. `la zero, ...`); record it, keep going.
            error = next((l for l in cc.stderr.splitlines() if "Error" in l), cc.stderr.strip()[:200])
            manifest.append({"program": name, "status": "GENERATOR_INVALID_ASM", "error": error.strip()})
            print(f"RISCVDV_SKIP {name}: generator produced invalid assembly: {error.strip()}")
            continue
        binary = images / f"{name}.bin"
        subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(elf), str(binary)], check=True)
        data = binary.read_bytes()
        entry = {"program": name, "bytes": len(data)}
        if len(data) > RAM_BYTES:
            entry["status"] = "TOO_BIG"
            print(f"RISCVDV_SKIP {name}: image {len(data)} bytes exceeds the {RAM_BYTES}-byte RAM")
            manifest.append(entry)
            continue
        (images / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in data) + "\n")
        try:
            r = run_case(name, Path.home() / ".local/bin/spike", program_dir=images,
                         out_dir=out / "spike", max_steps=MAX_STEPS, elf=elf)
            spike.append({"program": name, "result": "PASS", "register_commits": r["register_commits"],
                          "handled_traps": r["handled_traps"]})
            print(f"RISCVDV_SPIKE_PASS {name}: {r['register_commits']} commits, {r['handled_traps']} handled traps")
        except Exception as e:  # report and continue; the summary counts failures
            spike.append({"program": name, "result": "FAIL", "error": str(e)[:300]})
            print(f"RISCVDV_SPIKE_FAIL {name}: {str(e)[:300]}")
        entry["status"] = "READY"
        manifest.append(entry)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    (out / "spike.json").write_text(json.dumps(spike, indent=1))
    passed = sum(s["result"] == "PASS" for s in spike)
    print(f"RISCVDV_SPIKE_TOTAL pass={passed} of {len(spike)}; skipped={len(manifest) - len(spike)}")


if __name__ == "__main__":
    main(sys.argv[1])
