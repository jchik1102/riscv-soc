import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.accel_model import AccelModel

def replay(path):
    lines = Path(path).read_text().splitlines()
    _, n, parallel = lines[0].split(",")
    model = AccelModel(int(n), parallel == "1")
    level = 0
    pending = None
    stats = dict(requests=0, checked_reads=0, undefined_reads=0, errors=0, irq_changes=0, resets=0)
    for number, line in enumerate(lines[1:], 2):
        fields = line.split(",")
        where = f"{path}:{number}"
        if fields[0] == "RESET":
            model.reset()
            level, pending = 0, None
            stats["resets"] += 1
        elif fields[0] == "I":
            edge, level = int(fields[1]), int(fields[2])
            if int(model.irq(edge)) != level: raise AssertionError(f"{where}: irq {level}, model {int(model.irq(edge))}")
            stats["irq_changes"] += 1
        elif fields[0] == "Q":
            edge = int(fields[1])
            address, write, mask, wdata = (int(x, 16) for x in fields[2:6])
            if int(model.irq(edge)) != level: raise AssertionError(f"{where}: irq level {level} at edge {edge}, model {int(model.irq(edge))}")
            pending = (model.access(edge, address, write, mask, wdata), write, mask)
            stats["requests"] += 1
        elif fields[0] == "R":
            if pending is None: raise AssertionError(f"{where}: response without request")
            (error, rdata), write, mask = pending
            actual_error = int(fields[1], 16)
            actual = None if "x" in fields[2].lower() or "z" in fields[2].lower() else int(fields[2], 16)
            if actual_error != error: raise AssertionError(f"{where}: error {actual_error}, model {error}")
            stats["errors"] += error
            if actual is None and (error or write): raise AssertionError(f"{where}: undefined data in an error/write response")
            if not error and not write:
                if rdata is None: stats["undefined_reads"] += 1
                else:
                    if actual != rdata: raise AssertionError(f"{where}: rdata {fields[2]}, model {rdata:#018x}")
                    stats["checked_reads"] += 1
            pending = None
        else:
            raise AssertionError(f"{where}: malformed line")
    stats.update(n=int(n), parallel=parallel == "1", starts=model.starts, completions=model.completions)
    if model.completions == 0: raise AssertionError(f"{path}: no computation completed")
    return stats

def main():
    results = {}
    for path in sys.argv[1:]:
        results[Path(path).name] = stats = replay(path)
        print(f"PASS accelerator transcript {path}: {stats}")
    (ROOT / "build/xsim_accel/accel_unit_check.json").write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
