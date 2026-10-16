import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.reference import MAP
from model.rv64s4 import MachineS4

SPIKE_SKIP = {"s4_wfi": "WFI is a no-op in this design; Spike waits for an interrupt",
              "s5_fetch_fault": "instruction fetch from SDRAM faults in this design (code stays on-chip); Spike executes from any memory it models"}

def parse_commit(line):
    match = re.fullmatch(r"core\s+0:\s+3\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)", line)
    if not match:
        raise AssertionError(f"Unrecognized Spike commit: {line}")
    dest = re.search(r"(?:^|\s)x\s*(\d+)\s+0x([0-9a-f]+)", match[3])
    rd, value = (int(dest[1]), int(dest[2], 16)) if dest else (0, 0)
    memory = re.findall(r"\bmem\s+0x([0-9a-f]+)(?:\s+0x([0-9a-f]+))?", match[3])
    return (int(match[1], 16), int(match[2], 16), rd, value,
            [(int(address, 16), int(data, 16) if data else None) for address, data in memory])

def run_case(name, spike, program_dir=None, out_dir=None, max_steps=50000, elf=None):
    sdram = name.startswith(("s5_", "s6_", "s7_"))
    sdram_fetch = name.startswith("s6_")
    out = Path(out_dir) if out_dir else ROOT / "build/spike"
    out.mkdir(parents=True, exist_ok=True)
    program = (Path(program_dir) if program_dir else ROOT / "build/programs") / f"{name}.bin"
    if elf is None:
        # Wrap the raw image so Spike loads it at the reset PC.
        assembly = out / f"{name}.S"
        assembly.write_text(f'.section .text.init\n.global _start\n_start:\n.incbin "{program}"\n')
        elf = out / f"{name}.elf"
        subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv64im", "-mabi=lp64", "-nostdlib", "-nostartfiles",
                        "-Wl,--no-relax", "-T", "sw/link.ld", str(assembly), "-o", str(elf)], cwd=ROOT, check=True, timeout=30)
    # else: an ELF already linked at the reset PC whose image is `program` (riscv-dv)
    dis = subprocess.run(["riscv64-unknown-elf-objdump", "-d", str(elf)], capture_output=True, text=True, check=True)
    (out / f"{name}.dis").write_text(dis.stdout)
    machine = MachineS4(program.read_bytes(), sdram=sdram, sdram_fetch=sdram_fetch)
    expected = []
    steps = handled = 0
    for _ in range(max_steps):
        row = machine.step()
        if row["trap"] and machine.halted:
            break
        steps += 1
        if row["trap"]: handled += 1
        else: expected.append(row)
    else:
        raise AssertionError("Model watchdog expired")
    if not expected:
        raise AssertionError("Spike comparison requires a nonempty legal instruction prefix")
    log = out / f"{name}.log"
    memory = f"-m0x{MAP['ram_base']:x}:0x{MAP['ram_bytes']:x}"
    if sdram:
        memory += f",0x{MAP['memories']['sdram']['base']:x}:0x{MAP['memories']['sdram']['bytes']:x}"
    base = [str(spike), "--isa=rv64im_zicsr_zifencei", "--priv=m", "--disable-dtb", memory, f"--pc=0x{MAP['reset_pc']:x}"]
    if handled == 0:
        command = base + [f"--instructions={steps}", "--log-commits", f"--log={log}", str(elf)]
        run = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (out / f"{name}.stderr").write_text(run.stderr)
        if run.returncode:
            raise AssertionError(f"Spike failed: {run.stderr}")
    else:
        command = base + ["--log-commits", "--log=/dev/stdout", str(elf)]
        limit = len(expected) + handled
        shell = " ".join(shlex.quote(c) for c in ["timeout", "20"] + command) + f" 2>/dev/null | grep '^core' | head -n {limit}"
        run = subprocess.run(["bash", "-c", shell], capture_output=True, text=True, timeout=60)
        log.write_text(run.stdout)
        (out / f"{name}.stderr").write_text("unbounded run cut after expected commits\n")
    commits = []
    for line in log.read_text().splitlines():
        if line.strip() and not re.match(r"core\s+0:\s+(exception|tval)", line.strip()):
            commits.append(parse_commit(line))
    wanted = []
    for row in expected:
        memory = []
        if row['mem_wmask']:
            memory = [(row['mem_addr'], row['mem_wdata'] >> (8 * (row['mem_addr'] % 8)))]
        elif row['mem_rmask']:
            memory = [(row['mem_addr'], None)]
        wanted.append((row['pc'], row['insn'], row['rd'], row['rd_data'], memory))
    if commits != wanted:
        for i, (actual, want) in enumerate(zip(commits, wanted)):
            if actual != want:
                raise AssertionError(f"{name}: Spike/Python mismatch at {i}: {actual} != {want}")
        raise AssertionError(f"{name}: Spike commits {len(commits)} != model commits {len(wanted)}; inspect {log}")
    return {"program": name, "register_commits": len(commits), "handled_traps": handled,
            "load_commits": sum(bool(r['mem_rmask']) for r in expected),
            "store_commits": sum(bool(r['mem_wmask']) for r in expected),
            "result": "PASS", "command": command}

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("names", nargs="*")
    p.add_argument("--spike", default=str(Path.home() / ".local/bin/spike"))
    args = p.parse_args()
    names = args.names or (json.loads((ROOT / "build/programs/manifest.json").read_text()) +
                           json.loads((ROOT / "build/programs/manifest_s5.json").read_text()) +
                           json.loads((ROOT / "build/programs/manifest_s6.json").read_text()) +
                           json.loads((ROOT / "build/programs/manifest_s7.json").read_text()))
    results = []
    for name in names:
        if name in SPIKE_SKIP:
            print(f"SKIP Spike: {name} ({SPIKE_SKIP[name]})")
            results.append({"program": name, "result": "SKIPPED", "reason": SPIKE_SKIP[name],
                            "register_commits": 0, "load_commits": 0, "store_commits": 0})
            continue
        result = run_case(name, Path(args.spike))
        results.append(result)
        print(f"PASS Spike/Python: {name}, {result['register_commits']} commits")
    (ROOT / "build/spike/results.json").write_text(json.dumps(results, indent=2) + "\n")
