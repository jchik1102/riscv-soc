from model.accel_model import matmul, wrap32, latency

MASK = (1 << 64) - 1
MAGIC = 0x5337414343454c00
SEED = 0x5337414343454c31
FIXED_CASES = 6
RANDOM_CASES = {"s7_bench": 4, "s7_board": 58}
REPORT = 0x8000
OPERANDS, RESULTS = 0x400000, 0x500000
METRICS = ("software", "transfer", "compute", "readback", "complete", "complete_irq", "cycles_reg", "compute_irq")

def generate(cases):
    state = SEED
    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & MASK
        return state
    def rand8(): return ((nxt() >> 56) ^ 0x80) - 0x80
    def rand32(): return wrap32(nxt() >> 32)
    out = []
    for index in range(cases):
        a = [[0] * 4 for _ in range(4)]
        b = [[0] * 4 for _ in range(4)]
        c = [[0] * 4 for _ in range(4)]
        for i in range(4):
            for k in range(4):
                a[i][k] = (0 if index == 0 else int(i == k) if index == 1 else -128 if index in (2, 3)
                           else 127 if index == 4 else rand8())
        for k in range(4):
            for j in range(4):
                b[k][j] = -128 if index == 2 else 127 if index in (3, 4) else rand8()
        for i in range(4):
            for j in range(4):
                c[i][j] = 0x7fffffff if index == 2 else -(1 << 31) if index == 3 else rand32()
        acc = 1 if index in (0, 2, 3) else 0 if index < FIXED_CASES else nxt() >> 63
        out.append((a, b, c, acc))
    return out

def expected_results(build, n):
    cases = FIXED_CASES + RANDOM_CASES[build]
    results = []
    for a, b, c, acc in generate(cases):
        sub = lambda m: [row[:n] for row in m[:n]]
        results.append(matmul(sub(a), sub(b), sub(c) if acc else None))
    checksum = 0
    for d in results:
        for row in d:
            for x in row: checksum = (((checksum << 5) | (checksum >> 59)) & MASK) ^ (x & 0xffffffff)
    return results, checksum

def expected_report(build, n=4):
    results, checksum = expected_results(build, n)
    return {"checksum": checksum, "results": results}

def read_report(mem):
    word = lambda i: int.from_bytes(mem[REPORT + 8 * i:REPORT + 8 * i + 8], "little")
    head = [word(i) for i in range(8)]
    totals = [dict(zip(METRICS, (word(8 + 8 * m + k) for k in range(8)))) for m in range(2)]
    extra = {"accel_irqs": word(24), "bad_traps": word(25)}
    per_case = [[word(26 + 4 * c + k) for k in range(4)] for c in range(16)]
    return head, totals, extra, per_case

def sdram_word(model, offset):
    return int.from_bytes(bytes(model.sdram[offset:offset + 4]), "little")

def check_bench(name, model, checker, run, build="s7_bench"):
    (magic, checksum, status, ticks, mismatches, info, phase, cases), totals, extra, per_case = read_report(model.mem)
    n, parallel = run["accel_n"], run["accel_parallel"]
    want, want_checksum = expected_results(build, n)
    if (magic, status, mismatches, phase, cases) != (MAGIC, 1, 0, 3, len(want)):
        raise AssertionError(f"{name}: report magic/status/mismatches/phase/cases {(hex(magic), status, mismatches, phase, cases)}")
    if info & 0xff != n or (info >> 16) & 0xffff != latency(n, parallel):
        raise AssertionError(f"{name}: INFO {info:#x}")
    if checksum != want_checksum: raise AssertionError(f"{name}: software checksum differs from the contract")
    for mode in range(2):
        for index, d in enumerate(want):
            for run_kind in range(2):
                base = RESULTS + 64 * ((mode * len(want) + index) * 2 + run_kind)
                got = [[wrap32(sdram_word(model, base + 16 * i + 4 * j)) for j in range(n)] for i in range(n)]
                if got != d: raise AssertionError(f"{name}: accelerator result mode {mode} case {index} run {run_kind} {got} != {d}")
    if extra["accel_irqs"] != 2 * len(want) or extra["bad_traps"]: raise AssertionError(f"{name}: interrupts {extra}")
    if checker is not None and checker.external_since_reset != extra["accel_irqs"]:
        raise AssertionError(f"{name}: {checker.external_since_reset} external interrupt records since reset, firmware counted {extra['accel_irqs']}")
    if ticks < 1 or (checker is not None and ticks + extra["accel_irqs"] != checker.interrupts_since_reset):
        raise AssertionError(f"{name}: ticks {ticks}")
    for mode, t in enumerate(totals):
        if t["cycles_reg"] != len(want) * latency(n, parallel):
            raise AssertionError(f"{name}: CYCLES register sum {t['cycles_reg']} != {len(want)} x L")
        if t["complete"] != t["transfer"] + t["compute"] + t["readback"] or min(t.values()) <= 0:
            raise AssertionError(f"{name}: inconsistent timing totals {t}")
    return {"checksum": hex(checksum), "ticks": ticks, "n": n, "parallel": parallel, "cases": len(want),
            "totals_caches_on": totals[0], "totals_caches_off": totals[1], "per_case_caches_on": per_case[:len(want)]}
