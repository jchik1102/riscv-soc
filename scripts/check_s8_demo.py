from model.accel_model import matmul, wrap32
from scripts.check_s7_bench import generate, FIXED_CASES, RANDOM_CASES

MASK = (1 << 64) - 1
MAGIC = 0x533844454d4f0000
MATRIX_SEED = 0x533844454d4f3136
DIM = 16
REPORT = 0x8000
OPERANDS, MATRIX, MATRIX_RESULTS, CASE_RESULTS = 0x400000, 0x410000, 0x500000, 0x510000
CASES = {"s8_bench": FIXED_CASES + RANDOM_CASES["s7_bench"], "s8_board": FIXED_CASES + RANDOM_CASES["s7_board"]}
WORKLOADS = ("matrix", "cases")
MODES = ("caches_on", "caches_off")
METHODS = ("software", "polled", "interrupt")
METRICS = ("mcycle", "retired", "mem_wait", "arith", "d_access", "d_miss", "d_uncached", "d_write",
           "cycle", "fetch", "load_use", "redirect", "i_access", "i_miss", "i_uncached", "ticks")
CACHE_METRICS = ("d_access", "d_miss", "d_uncached", "d_write", "i_access", "i_miss", "i_uncached")
HEAD = ("magic", "checksum", "status", "ticks", "mismatches", "info", "phase", "cases", "accel_irqs",
        "bad_traps", "dim", "tile_runs", "counter_errors")

def make_matrix():
    state = MATRIX_SEED
    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & MASK
        return state
    def rand8(): return ((nxt() >> 56) ^ 0x80) - 0x80
    def rand32(): return wrap32(nxt() >> 32)
    a = [[-128 if i == 0 else rand8() for k in range(DIM)] for i in range(DIM)]
    b = [[-128 if j == 0 else rand8() for j in range(DIM)] for k in range(DIM)]
    c = [[0x7fffffff if i == 0 and j == 0 else rand32() for j in range(DIM)] for i in range(DIM)]
    return a, b, c

def expected_results(build, n):
    a, b, c = make_matrix()
    big = matmul(a, b, c)
    cases = []
    for ca, cb, cc, acc in generate(CASES[build]):
        sub = lambda m: [row[:n] for row in m[:n]]
        cases.append(matmul(sub(ca), sub(cb), sub(cc) if acc else None))
    checksum = 0
    for d in [big] + cases:
        for row in d:
            for x in row: checksum = (((checksum << 5) | (checksum >> 59)) & MASK) ^ (x & 0xffffffff)
    return big, cases, checksum

def expected_report(build, n=4):
    big, cases, checksum = expected_results(build, n)
    return {"checksum": checksum, "matrix": big, "cases": cases}

def read_report(mem):
    word = lambda i: int.from_bytes(mem[REPORT + 8 * i:REPORT + 8 * i + 8], "little")
    head = dict(zip(HEAD, (word(i) for i in range(len(HEAD)))))
    metrics = {}
    for w, workload in enumerate(WORKLOADS):
        for m, mode in enumerate(MODES):
            for k, method in enumerate(METHODS):
                base = 16 + ((w * 2 + m) * 4 + k) * 16
                metrics[(workload, mode, method)] = dict(zip(METRICS, (word(base + i) for i in range(16))))
    return head, metrics

def sdram_word(model, offset):
    return wrap32(int.from_bytes(bytes(model.sdram[offset:offset + 4]), "little"))

def windows_from_marks(marks, snapshots):
    out, start = [], None
    for data, snap in zip(marks, snapshots):
        if data & 1: start = snap
        elif start is not None:
            out.append({k: snap[k] - start[k] for k in CACHE_METRICS})
            start = None
    return out

def check_demo(name, model, checker, run, build="s8_bench", windows=None):
    head, metrics = read_report(model.mem)
    n = run["accel_n"]
    big, cases, checksum = expected_results(build, n)
    tiles = DIM // n
    want_head = {"magic": MAGIC, "status": 1, "mismatches": 0, "phase": 3, "cases": len(cases), "bad_traps": 0,
                 "dim": DIM, "tile_runs": tiles ** 3, "counter_errors": 0, "checksum": checksum,
                 "accel_irqs": 2 * (tiles ** 3 + len(cases))}
    for key, value in want_head.items():
        if head[key] != value: raise AssertionError(f"{name}: report {key} = {head[key]:#x}, expected {value:#x}")
    if head["info"] & 0xff != n: raise AssertionError(f"{name}: INFO {head['info']:#x}")
    for slot in range(6):
        base = MATRIX_RESULTS + slot * DIM * DIM * 4
        got = [[sdram_word(model, base + 4 * (DIM * i + j)) for j in range(DIM)] for i in range(DIM)]
        if got != big: raise AssertionError(f"{name}: 16x16 result {MODES[slot // 3]} {METHODS[slot % 3]} differs from the contract")
        for index, d in enumerate(cases):
            base = CASE_RESULTS + 64 * (slot * len(cases) + index)
            got = [[sdram_word(model, base + 16 * i + 4 * j) for j in range(n)] for i in range(n)]
            if got != d: raise AssertionError(f"{name}: case {index} {MODES[slot // 3]} {METHODS[slot % 3]} {got} != {d}")
    if checker is not None:
        if checker.external_since_reset != head["accel_irqs"]:
            raise AssertionError(f"{name}: {checker.external_since_reset} external interrupt records, firmware counted {head['accel_irqs']}")
        if head["ticks"] < 1 or head["ticks"] + head["accel_irqs"] != checker.interrupts_since_reset:
            raise AssertionError(f"{name}: ticks {head['ticks']}")
    order = [(w, m, k) for m in MODES for w in WORKLOADS for k in METHODS]
    if windows is not None and len(windows) != len(order):
        raise AssertionError(f"{name}: {len(windows)} counter windows in the transcript, expected {len(order)}")
    for index, key in enumerate(order):
        t = metrics[key]
        if min(t["mcycle"], t["retired"], t["cycle"]) <= 0 or t["cycle"] > t["mcycle"] or t["retired"] > t["cycle"]:
            raise AssertionError(f"{name}: implausible window {key}: {t}")
        if windows is not None:
            for k in CACHE_METRICS:
                if t[k] != windows[index][k]:
                    raise AssertionError(f"{name}: window {key} counter {k} = {t[k]}, cache model {windows[index][k]}")
        if key[2] == "software" and t["arith"] == 0:
            raise AssertionError(f"{name}: software window {key} without M-unit activity")
    if sum(t["ticks"] for t in metrics.values()) > head["ticks"]:
        raise AssertionError(f"{name}: window ticks exceed the total")
    summary = {"checksum": hex(checksum), "ticks": head["ticks"], "n": n, "cases": len(cases),
               "tile_runs": tiles ** 3, "accel_irqs": head["accel_irqs"],
               "counter_windows_checked": 0 if windows is None else len(windows),
               "windows": {"/".join(key): metrics[key] for key in order}}
    summary["speedup"] = {f"{w}/{m}": {meth: round(metrics[(w, m, "software")]["mcycle"] / metrics[(w, m, meth)]["mcycle"], 2)
                                       for meth in ("polled", "interrupt")} for w in WORKLOADS for m in MODES}
    summary["caches_effect"] = {f"{w}/{meth}": round(metrics[(w, "caches_off", meth)]["mcycle"] / metrics[(w, "caches_on", meth)]["mcycle"], 2)
                                for w in WORKLOADS for meth in METHODS}
    return summary
