"""Convert the ACT4 self-checking ELFs into pipe_tb images.

For each ELF under <workdir>/riscv-soc-rv64im/elfs this writes
build/act4/images/<test>.hex (one byte per line from RAM_BASE, the format
scripts/programs.py uses) and a manifest with the offset of `tohost`, where
RVMODEL_HALT_PASS/FAIL store the result (1 = pass, 3 = fail).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINUTILS = Path.home() / "riscv-tools/gcc-nightly-2026.08.27/bin"
RAM_BASE = 0x8000_0000
MEM_BYTES = 0x4_0000  # pipe_tb with +define+TB_MEM_BYTES


def tool(name):
    return str(BINUTILS / f"riscv64-unknown-elf-{name}")


def symbol(elf, name):
    out = subprocess.run([tool("nm"), str(elf)], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return int(parts[0], 16)
    raise ValueError(f"{elf.name}: no symbol {name}")


def main(workdir):
    elfs = sorted(Path(workdir, "riscv-soc-rv64im", "elfs").rglob("*.elf"))
    if not elfs:
        raise SystemExit(f"no ELFs under {workdir}")
    out = ROOT / "build/act4/images"
    out.mkdir(parents=True, exist_ok=True)
    manifest = []
    for elf in elfs:
        name = elf.stem
        start = RAM_BASE  # .text.init is linked at TEST_BASE = RAM_ORIGIN
        binary = out / f"{name}.bin"
        subprocess.run([tool("objcopy"), "-O", "binary", str(elf), str(binary)], check=True)
        data = binary.read_bytes()
        if len(data) > MEM_BYTES:
            raise SystemExit(f"{name}: image is {len(data)} bytes, larger than the {MEM_BYTES}-byte testbench memory")
        (out / f"{name}.hex").write_text("@00000000\n" + "\n".join(f"{b:02x}" for b in data) + "\n")
        tohost = symbol(elf, "tohost")
        manifest.append({"test": name, "suite": elf.parent.name, "elf": str(elf), "bytes": len(data),
                         "tohost_offset": tohost - start})
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"ACT_IMAGES: {len(manifest)} images in {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv[1])
