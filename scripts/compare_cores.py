import argparse
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def retirements(path):
    rows = []
    with path.open() as stream:
        header = stream.readline()
        for line in stream:
            if line.strip() == "RESET": raise ValueError(f"{path} contains a reset")
            if line.split(",", 1)[0] in ("Q", "R", "IQ", "IR"): continue
            rows.append(line.strip())
    header = header.strip()
    if header.endswith(",intr"):
        if any(not row.endswith(",0") for row in rows): raise AssertionError(f"{path}: interrupt record")
        header, rows = header[:-len(",intr")], [row[:-2] for row in rows]
    return header, rows

def cycles(log):
    text = log.read_text(errors="replace")
    line = next(l for l in text.splitlines() if l.startswith("CORE_TB_DONE"))
    return int(line.split("cycles=")[1].split()[0])

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--suffix", default="_s1_d5_r-1")
    args = p.parse_args()
    names = [n for n in json.loads((ROOT / "build/programs/manifest.json").read_text())
             if not n.startswith("s4_") and n not in ("fault_csr", "fault_mret")]
    results = []
    for name in names:
        multi = ROOT / "build/xsim_core" / f"{name}{args.suffix}.csv"
        pipe = ROOT / "build/xsim_pipe" / f"{name}{args.suffix}.csv"
        h1, r1 = retirements(multi)
        h2, r2 = retirements(pipe)
        if h1 != h2 or r1 != r2:
            first = next((i for i, (a, b) in enumerate(zip(r1, r2)) if a != b), min(len(r1), len(r2)))
            raise AssertionError(f"{name}: retirement mismatch at row {first} ({len(r1)} vs {len(r2)} rows)")
        if Path(f"{multi}.mem").read_bytes() != Path(f"{pipe}.mem").read_bytes():
            raise AssertionError(f"{name}: final RAM differs between configurations")
        results.append({"program": name, "records": len(r1),
                        "multicycle_cycles": cycles(multi.with_suffix(".log")),
                        "pipeline_cycles": cycles(pipe.with_suffix(".log"))})
        print(f"PASS identical retirements: {name}, {len(r1)} records")
    (ROOT / "build/core_comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"PASS: {len(results)} programs, {sum(r['records'] for r in results)} identical records")

if __name__ == "__main__":
    main()
