import json
from pathlib import Path

try:
    import numpy as np
except ImportError:
    np = None

MAP = json.loads((Path(__file__).resolve().parents[1] / "config/address_map.json").read_text())
BASE = MAP["reserved"]["accelerator"]["base"]
BYTES = MAP["reserved"]["accelerator"]["bytes"]
REGS = MAP["accel_regs"]
CTRL, STATUS, INFO, CYCLES = REGS["ctrl"], REGS["status"], REGS["info"], REGS["cycles"]
A_OFF, B_OFF, C_OFF, D_OFF = REGS["a"], REGS["b"], REGS["c"], REGS["d"]
VERSION = 1
MASK32 = (1 << 32) - 1

def wrap32(value):
    value &= MASK32
    return value - (1 << 32) if value >> 31 else value

def s8(value):
    value &= 0xff
    return value - 256 if value >> 7 else value

def matmul(a, b, c=None):
    n = len(a)
    for row in a + b:
        if len(row) != n or any(not -128 <= x <= 127 for x in row): raise ValueError("A/B must be N x N INT8")
    if c is not None and any(not -(1 << 31) <= x < (1 << 31) for row in c for x in row):
        raise ValueError("C must be INT32")
    return [[wrap32(sum(a[i][k] * b[k][j] for k in range(n)) + (c[i][j] if c is not None else 0))
             for j in range(n)] for i in range(n)]

def matmul_numpy(a, b, c=None):
    if np is None: raise RuntimeError("NumPy not available")
    a64 = np.asarray(a, dtype=np.int8).astype(np.int64)
    b64 = np.asarray(b, dtype=np.int8).astype(np.int64)
    total = a64 @ b64
    if c is not None: total = total + np.asarray(c, dtype=np.int32).astype(np.int64)
    return (((total + (1 << 31)) % (1 << 32)) - (1 << 31)).astype(np.int32).tolist()

def latency(n, parallel):
    return n if parallel else n ** 3

def info_value(n, parallel):
    return (VERSION << 32) | (latency(n, parallel) << 16) | ((n * n if parallel else 1) << 8) | n

class AccelModel:

    def __init__(self, n=4, parallel=True):
        if n not in (2, 4): raise ValueError("N must be 2 or 4")
        self.n, self.parallel = n, parallel
        self.latency = latency(n, parallel)
        self.starts = self.completions = 0
        self.reset()

    def reset(self):
        n = self.n
        self.a = [[None] * n for _ in range(n)]
        self.b = [[None] * n for _ in range(n)]
        self.c = [[None] * n for _ in range(n)]
        self.d = [[None] * n for _ in range(n)]
        self.ie = self.acc = False
        self.done = self.start_ignored = False
        self.e0 = None
        self.result = None
        self.cycles_last = 0

    def _busy_before(self, edge):
        return self.e0 is not None and self.result is not None and self.e0 < edge <= self.e0 + self.latency

    def advance(self, edge):
        if self.e0 is not None and self.result is not None and edge - 1 >= self.e0 + self.latency:
            self.d = self.result
            self.result = None
            self.done = True
            self.cycles_last = self.latency
            self.completions += 1

    def busy(self, edge):
        self.advance(edge)
        return self._busy_before(edge)

    def irq(self, edge):
        self.advance(edge)
        return self.done and self.ie

    def _cycles(self, edge):
        if self._busy_before(edge): return min(edge - 1 - self.e0, self.latency)
        return self.cycles_last

    def _word(self, offset):
        n = self.n
        if offset < 0x20: return ("reg", offset // 8, offset % 8 // 4)
        index = (offset & 0xff) // 4
        region = offset & ~0xff
        if region == A_OFF and index < n: return ("a", index, 0)
        if region == B_OFF and index < n: return ("b", index, 0)
        if region == C_OFF and index < n * n: return ("c", index // n, index % n)
        if region == D_OFF and index < n * n: return ("d", index // n, index % n)
        return None

    def _read_word(self, edge, kind, i, j):
        n = self.n
        if kind == "reg":
            register, half = i, j
            if register == CTRL // 8: value = (int(self.acc) << 2) | (int(self.ie) << 1)
            elif register == STATUS // 8:
                value = (int(self.start_ignored) << 2) | (int(self.done) << 1) | int(self._busy_before(edge))
            elif register == INFO // 8: value = info_value(n, self.parallel)
            else: value = self._cycles(edge)
            return (value >> (32 * half)) & MASK32
        if kind in ("a", "b"):
            row = (self.a if kind == "a" else self.b)[i]
            if any(x is None for x in row): return None
            return sum((x & 0xff) << (8 * k) for k, x in enumerate(row))
        if kind == "d" and self._busy_before(edge): return None
        value = (self.c if kind == "c" else self.d)[i][j]
        return None if value is None else value & MASK32

    def access(self, edge, address, write, mask, wdata=0):
        self.advance(edge)
        offset = address - BASE
        if not 0 <= offset < BYTES or offset % 8: raise ValueError("not an accelerator beat")
        if mask not in (0x0f, 0xf0, 0xff): return 1, 0
        halves = [h for h in (0, 1) if mask >> (4 * h) & 0xf]
        words = [self._word(offset + 4 * h) for h in halves]
        if any(w is None for w in words): return 1, 0
        busy = self._busy_before(edge)
        if write:
            for kind, _, _ in words:
                if kind == "d" or (busy and kind in ("a", "b", "c")): return 1, 0
            for h, (kind, i, j) in zip(halves, words):
                value = (wdata >> (32 * h)) & MASK32
                if kind == "a": self.a[i] = [s8(value >> (8 * k)) for k in range(self.n)]
                elif kind == "b": self.b[i] = [s8(value >> (8 * k)) for k in range(self.n)]
                elif kind == "c": self.c[i][j] = wrap32(value)
                elif kind == "reg" and h == 0:
                    if i == CTRL // 8: self._ctrl(edge, value, busy)
                    elif i == STATUS // 8:
                        if value & 2: self.done = False
                        if value & 4: self.start_ignored = False
            return 0, 0
        rdata = 0
        for h, (kind, i, j) in zip(halves, words):
            value = self._read_word(edge, kind, i, j)
            if value is None: return 0, None
            rdata |= value << (32 * h)
        return 0, rdata

    def _ctrl(self, edge, value, busy):
        self.ie, self.acc = bool(value & 2), bool(value & 4)
        if not value & 1: return
        if busy:
            self.start_ignored = True
            return
        n = self.n
        defined = all(x is not None for m in (self.a, self.b) for row in m for x in row)
        c = [[x if self.acc else 0 for x in row] for row in self.c]
        if defined and all(x is not None for row in c for x in row):
            self.result = matmul(self.a, self.b, c)
        else:
            self.result = [[None] * n for _ in range(n)]
        self.e0 = edge
        self.done = False
        self.cycles_last = 0
        self.d = [[None] * n for _ in range(n)]
        self.starts += 1
