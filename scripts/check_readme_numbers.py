#!/usr/bin/env python3
"""Check that the numbers in README.md appear in the result files they cite.

For every README line that links to something under results/, each number on
that line (three or more digits, commas ignored) must appear in one of the
linked files, or in a folder the line links to. Numbers that are derived
(a sum, a percentage, an Fmax computed from slack) or that come from another
file are listed in scripts/readme_numbers_allow.txt, one per line:

    <number> <path under the repository>    the number must appear in that file
    <number> derived: <how it is computed>  accepted, with the reason on record
    <number> text: <why it is not a result> versions, dates, sizes, addresses

The same script is used in riscv-soc, tensor-accelerator and
fpga-network-engine. Exit status 1 if any number is unaccounted for, or if an
allow-list entry is unused or points at a file that does not hold the number.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.md")
ALLOW = os.path.join(ROOT, "scripts", "readme_numbers_allow.txt")
NUMBER = re.compile(r"(?<![\w.])\d[\d,]*(?:\.\d+)?")
MAX_FILES_PER_FOLDER = 2000


def read(path):
    with open(path, encoding="utf-8", errors="ignore") as handle:
        return handle.read().replace(",", "")


def linked_text(link, cache):
    path = os.path.join(ROOT, link)
    if path in cache:
        return cache[path]
    files = []
    if os.path.isdir(path):
        for folder, _, names in os.walk(path):
            files += [os.path.join(folder, name) for name in sorted(names)]
        files = files[:MAX_FILES_PER_FOLDER]
    elif os.path.isfile(path):
        files = [path]
    cache[path] = "".join(read(name) for name in files)
    return cache[path]


def load_allow():
    entries = {}
    if not os.path.exists(ALLOW):
        return entries
    with open(ALLOW, encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            number, _, reason = line.partition(" ")
            entries[number.replace(",", "")] = reason.strip()
    return entries


def main():
    allow = load_allow()
    used, problems, checked, cache = set(), [], 0, {}
    with open(README, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    for line_number, line in enumerate(lines, 1):
        links = [target.split("#")[0] for target in re.findall(r"\]\(([^)]+)\)", line)]
        links = [target for target in links if target.startswith("results")]
        if not links:
            continue
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", " ", line)   # drop link text and targets
        text = re.sub(r"`[^`]*`", " ", text)                   # drop code spans
        evidence = "".join(linked_text(link, cache) for link in links)
        for token in sorted(set(NUMBER.findall(text))):
            number = token.rstrip(",").replace(",", "")
            if len(number.replace(".", "")) < 3:
                continue
            checked += 1
            if number in evidence:
                continue
            reason = allow.get(number)
            if reason is None:
                problems.append(f"README.md:{line_number}: {token} is not in {', '.join(links[:3])}")
                continue
            used.add(number)
            if reason.startswith(("derived:", "text:")):
                continue
            other = os.path.join(ROOT, reason)
            if not os.path.isfile(other) or number not in read(other):
                problems.append(f"README.md:{line_number}: {token} is not in {reason} (allow-list)")
    for number in sorted(set(allow) - used):
        problems.append(f"readme_numbers_allow.txt: entry {number} is not needed")
    for problem in problems:
        print(problem)
    print(f"README_NUMBERS {'FAIL' if problems else 'PASS'}: {checked} numbers checked, "
          f"{len(used)} from the allow-list, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
