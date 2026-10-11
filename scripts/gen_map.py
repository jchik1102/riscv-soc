import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def generate(check=False):
    m = json.loads((ROOT / "config/address_map.json").read_text())
    constants = {k.upper(): v for k, v in m.items() if isinstance(v, int)}
    regions = list(m.get("memories", {}).items()) + list(m["reserved"].items()) + list(m.get("devices", {}).items())
    regions += [("caches", m.get("caches", {}))]
    regions += [(name, m.get(name, {})) for name in ("interrupts", "accel", "accel_regs")]
    for name, region in regions:
        for key, value in region.items():
            constants[f"{name.upper()}_{key.upper()}"] = value
    outputs = {
        "rtl/soc/platform_pkg.sv": "package platform_pkg;\n" + "".join(f"  localparam logic [63:0] {k} = 64'h{v:016x};\n" for k, v in constants.items()) + "endpackage\n",
        "sw/platform.h": "#ifndef PLATFORM_H\n#define PLATFORM_H\n" + "".join(f"#define PLATFORM_{k} 0x{v:x}UL\n" for k, v in constants.items()) + "#endif\n",
        "sw/memory.ld": f"MEMORY {{ RAM (rwx) : ORIGIN = 0x{m['ram_base']:x}, LENGTH = 0x{m['ram_bytes']:x} }}\n",
    }
    for name, content in outputs.items():
        path = ROOT / name
        if check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"Stale generated map: {name}")
        else:
            path.write_text(content)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true")
    generate(p.parse_args().check)
