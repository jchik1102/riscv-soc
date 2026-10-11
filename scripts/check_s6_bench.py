MASK = (1 << 64) - 1
MAGIC = 0x5336434143484500
SIZES = {"s6_bench": (128, 512, 3), "s6_board": (256, 4096, 8)}
REPORT = 0x8000
EVENTS = ("i_access", "i_miss", "i_uncached", "d_access", "d_miss", "d_uncached", "d_write")

def expected_results(build="s6_bench"):
    small, big, rounds = SIZES[build]
    x, data = 0x243f6a8885a308d3, []
    for _ in range(big):
        x = (x * 6364136223846793005 + 1442695040888963407) & MASK
        data.append(x)
    def kernel(n):
        s = 0
        for r in range(rounds):
            for i in range(n): s = ((s ^ data[i]) + (s << 7) + (s >> 3) + r) & MASK
        return s
    results = [kernel(small), kernel(big)] * 2
    checksum = 0
    for value in results: checksum = (((checksum << 7) | (checksum >> 57)) & MASK) ^ value
    return results, checksum

def read_report(mem):
    word = lambda i: int.from_bytes(mem[REPORT + 8 * i:REPORT + 8 * i + 8], "little")
    head = [word(i) for i in range(8)]
    cycles = [[word(8 + 4 * m + w) for w in range(4)] for m in range(4)]
    events = [dict(zip(EVENTS, (word(24 + 7 * m + e) for e in range(7)))) for m in range(4)]
    results = [[word(52 + 4 * m + w) for w in range(4)] for m in range(4)]
    return head, cycles, events, results

def check_bench(name, model, checker, run=None, build="s6_bench"):
    (magic, checksum, status, ticks, mismatches, info, phase, _), cycles, events, results = read_report(model.mem)
    want_results, want_checksum = expected_results(build)
    if (magic, status, mismatches, phase) != (MAGIC, 1, 0, 5):
        raise AssertionError(f"{name}: report magic/status/mismatches/phase {(hex(magic), status, mismatches, phase)}")
    if checksum != want_checksum or any(r != want_results for r in results):
        raise AssertionError(f"{name}: kernel results differ from the contract")
    if ticks < 1 or (checker is not None and ticks != checker.interrupts_since_reset):
        raise AssertionError(f"{name}: ticks {ticks}")
    for mode, e in enumerate(events):
        for c, bit in (("i", 0), ("d", 1)):
            on, was_on = mode >> bit & 1, (mode - 1) >> bit & 1 if mode else 0
            if ((e[c + "_access"] > 0) != bool(on) or (e[c + "_uncached"] > 0) == bool(on) or
                    (on and not was_on and e[c + "_miss"] == 0) or (not on and e[c + "_miss"])):
                raise AssertionError(f"{name}: {c.upper()}-cache events {e} for mode {mode}")
    return {"checksum": hex(checksum), "ticks": ticks, "cycles": cycles, "events": events}
