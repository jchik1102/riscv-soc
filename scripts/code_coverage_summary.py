"""Summarize an XSim (xcrg) code coverage HTML report for the design under test.

xcrg writes code coverage only as HTML, and its totals include every module
in the snapshot, testbench too. This reads the per-module pages, keeps the
modules that have an instance under one of the --dut hierarchy prefixes, and
writes per-module and total statement, branch and condition counts, then the
line numbers of statements that never executed. A module with several
instances is counted once, as xcrg reports it (all instances combined).

usage: code_coverage_summary.py REPORT_DIR --dut PREFIX [--dut PREFIX ...]
                                --label NAME --out FILE [--root PATH]
REPORT_DIR is the xcrg -report_dir (it contains codeCoverageReport/); --root
is the repository path as XSim saw it, removed from source paths.
The last line is CODE_COVERAGE <label> statements=a/b (p%) branches=...
"""
import argparse
import html
import re
import sys
from pathlib import Path

KINDS = (("statements", "Statement"), ("branches", "Branch"), ("conditions", "Condition"))


def cells(row):
    return [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)]


def section(page, title):
    start = page.find(f"{title} Coverage Summary for Module")
    if start < 0:
        return ""
    ends = [page.find(f"{t} Coverage Summary for Module", start + 1) for _, t in KINDS]
    ends = [e for e in ends if e > start]
    return page[start:min(ends)] if ends else page[start:]


def module_counts(page):
    """(covered, total) for each kind, from the module page's summary tables."""
    counts = {}
    for key, title in KINDS:
        text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", section(page, title)))
        if key == "statements":
            m = re.search(r"Statement Coverage Score (\d+) (\d+) (\d+) (\d+) ([0-9.]+)", text)
            counts[key] = (int(m.group(3)), int(m.group(2))) if m else (0, 0)
        else:
            m = re.search(rf"{title} Coverage Score (\d+) (\d+) (\d+) ([0-9.]+)", text)
            counts[key] = (int(m.group(2)), int(m.group(1))) if m else (0, 0)
    return counts


def uncovered_lines(page):
    lines = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", section(page, "Statement"), re.S):
        c = cells(row)
        if len(c) == 4 and c[0].isdigit() and c[2] == "0" and c[3]:
            lines.append(int(c[0]))
    return lines


def pct(covered, total):
    return f"{100.0 * covered / total:.2f}%" if total else "n/a"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report_dir", type=Path)
    parser.add_argument("--dut", action="append", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--root", default="")
    args = parser.parse_args()
    root = args.root.replace("\\", "/").rstrip("/").lower() + "/"
    report = args.report_dir / "codeCoverageReport"
    index = (report / "modules.html").read_text(encoding="utf-8", errors="replace")
    modules = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", index, re.S):
        c = cells(row)
        link = re.search(r"href=['\"]?(mod[^'\" >]+)", row)
        if len(c) == 9 and c[0].isdigit() and link:
            instances = c[3].split()
            if any(i == p or i.startswith(p + ".") for i in instances for p in args.dut):
                source = c[7].replace("\\", "/")
                if root != "/" and source.lower().startswith(root):
                    source = source[len(root):]
                modules.append((link.group(1), c[1], int(c[2]), source))
    if not modules:
        sys.exit(f"no module has an instance under {args.dut}")
    out = [f"XSim code coverage ({args.label}): statement, branch and condition, merged over every run",
           f"design under test: instances under {', '.join(args.dut)}; testbench modules excluded",
           "", f"{'module':44} {'inst':>4}  {'statements':>18}  {'branches':>18}  {'conditions':>18}"]
    total = {k: [0, 0] for k, _ in KINDS}
    holes = []
    for page_name, name, count, source in sorted(modules, key=lambda m: m[1]):
        page = (report / page_name).read_text(encoding="utf-8", errors="replace")
        counts = module_counts(page)
        for k, _ in KINDS:
            total[k][0] += counts[k][0]
            total[k][1] += counts[k][1]
        out.append(f"{name:44} {count:>4}  " + "  ".join(
            f"{counts[k][0]:>5}/{counts[k][1]:<5} {pct(*counts[k]):>7}" for k, _ in KINDS))
        missed = uncovered_lines(page)
        if missed:
            holes.append(f"{name} ({source}): {', '.join(map(str, missed))}")
    out.append(f"{'TOTAL':44} {'':>4}  " + "  ".join(
        f"{total[k][0]:>5}/{total[k][1]:<5} {pct(*total[k]):>7}" for k, _ in KINDS))
    out += ["", "Lines with a statement that never executed:"] + (holes or ["(none)"])
    summary = " ".join(f"{k}={total[k][0]}/{total[k][1]} ({pct(*total[k])})" for k, _ in KINDS)
    out += ["", f"CODE_COVERAGE {args.label} {summary}"]
    args.out.write_text("\n".join(out) + "\n")
    print(f"CODE_COVERAGE {args.label} {summary}")


if __name__ == "__main__":
    main()
