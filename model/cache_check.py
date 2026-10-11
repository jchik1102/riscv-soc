import copy
from collections import deque
from pathlib import Path
import csv
from model.rv64i import MAP, MASK, read_hex
from model.pipeline_check import PipelineChecker, SDRAM_BASE, SDRAM_BYTES, read_sdram_dump

CACHE_CTRL = MAP["devices"]["cache"]["base"]
LINE = MAP["caches"]["line_bytes"]
COUNTER_NAMES = ("i_access", "i_miss", "i_uncached", "d_access", "d_miss", "d_uncached", "d_write")

def in_sdram(address):
    return SDRAM_BASE <= address < SDRAM_BASE + SDRAM_BYTES

class DirectMapped:
    def __init__(self, size):
        self.size = size
        self.lines = size // LINE
        self.clear()

    def clear(self):
        self.tags = [None] * self.lines

    def locate(self, address):
        offset = address - SDRAM_BASE
        return (offset // LINE) % self.lines, offset // self.size

    def hit(self, address):
        index, tag = self.locate(address)
        return self.tags[index] == tag

    def fill(self, address):
        index, tag = self.locate(address)
        self.tags[index] = tag

class CachedChecker(PipelineChecker):
    def __init__(self, program, icache_bytes, dcache_bytes, enable_init):
        self.icache = DirectMapped(icache_bytes)
        self.dcache = DirectMapped(dcache_bytes)
        self.enable_init = enable_init
        self.counts = dict.fromkeys(COUNTER_NAMES, 0)
        self.observed = {"D": Counter2(), "I": Counter2()}
        self.fence_i = 0
        self.history = {}
        self.cycle = 0
        self.snapshots = {}
        self.watch = set()
        super().__init__(program, sdram=True)
        self.model.sdram_fetch = True
        self.ahead.sdram_fetch = True

    def reset(self):
        super().reset()
        self.model.sdram_fetch = True
        if hasattr(self, "icache"):
            self.icache.clear(); self.dcache.clear()
            self.enable = [bool(self.enable_init & 1), bool(self.enable_init & 2)]
            self.expected = {"D": deque(), "I": deque()}
            self.history = {}
            self.counts = dict.fromkeys(COUNTER_NAMES, 0)

    def _resync(self):
        super()._resync()
        self.ahead.sdram_fetch = True

    def set_enable(self, which, value):
        self.enable[which] = value
        if not value: (self.icache if which == 0 else self.dcache).clear()

    def fetch_request(self, fields):
        super().fetch_request(fields)
        address = self.fetch_out
        if in_sdram(address):
            if not self.enable[0]:
                self.counts["i_uncached"] += 1
                self.expected["I"].append((address, 0, 0xff, 0, 0))
            else:
                self.counts["i_access"] += 1
                if not self.icache.hit(address):
                    self.expected["I"].append((address & ~(LINE - 1), 0, 0xff, 0, 3))
                    self.icache.fill(address)

    def fetch_response(self, fields):
        if self.fetch_out is None or not in_sdram(self.fetch_out):
            return super().fetch_response(fields)
        error, rdata = int(fields[0], 16), int(fields[1], 16)
        if error: raise AssertionError(f"Fetch error from SDRAM at {self.fetch_out:#x}")
        offset = self.fetch_out - SDRAM_BASE
        for lane in range(8):
            value = (rdata >> (8 * lane)) & 255
            current = self._sdram_byte(offset + lane)
            if current is None: continue
            allowed = {current} | self.history.get(offset + lane, set())
            if value not in allowed:
                raise AssertionError(f"Fetch from SDRAM {self.fetch_out + lane:#x}: byte {value:#04x} is neither the current "
                                     f"value {current:#04x} nor one held since the last FENCE.I")
        self.fetch_out = None

    def _sdram_byte(self, offset):
        page = self.phys_sdram.pages.get(offset // self.phys_sdram.PAGE)
        if page is None or not page[1][offset % self.phys_sdram.PAGE]: return None
        return page[0][offset % self.phys_sdram.PAGE]

    def fence(self):
        if self.fetch_out is not None: raise AssertionError("FENCE.I with a fetch outstanding")
        self.icache.clear()
        self.history = {}
        self.fence_i += 1

    def data_request(self, fields):
        address, write, mask, data = (int(x, 16) for x in fields)
        before = {}
        if write and in_sdram(address):
            for lane in range(8):
                if mask >> lane & 1: before[address - SDRAM_BASE + lane] = self._sdram_byte(address - SDRAM_BASE + lane)
        super().data_request(fields)
        if in_sdram(address) and address % 8 == 0 and address <= SDRAM_BASE + SDRAM_BYTES - 8:
            if write:
                self.counts["d_write"] += 1
                if self.enable[1]: self.counts["d_access"] += 1
                self.expected["D"].append((address, 1, mask, data, 0))
                for offset, old in before.items():
                    if old is not None: self.history.setdefault(offset, set()).add(old)
            elif not self.enable[1]:
                self.counts["d_uncached"] += 1
                self.expected["D"].append((address, 0, mask, 0, 0))
            else:
                self.counts["d_access"] += 1
                if not self.dcache.hit(address):
                    self.expected["D"].append((address & ~(LINE - 1), 0, 0xff, 0, 3))
                    self.dcache.fill(address)
        elif write and address == CACHE_CTRL and mask & 1:
            self.set_enable(0, bool(data & 1))
            self.set_enable(1, bool(data & 2))

    def memory_request(self, master, fields):
        actual = tuple(int(x, 16) for x in fields)
        if not self.expected[master]:
            raise AssertionError(f"Unpredicted {master}-cache memory transaction {actual}")
        want = self.expected[master].popleft()
        if actual != want:
            raise AssertionError(f"{master}-cache memory transaction {actual}, expected {want}")
        if want[4] == 3:
            self.counts["i_miss" if master == "I" else "d_miss"] += 1
        self.observed[master].add(want)

    def end_cycle(self):
        if self.cycle in self.watch: self.snapshots[self.cycle] = dict(self.counts)

    def start_cycle(self, cycle):
        self.end_cycle()
        self.cycle = cycle

class Counter2:
    def __init__(self):
        self.fills = self.reads = self.writes = 0

    def add(self, txn):
        if txn[4] == 3: self.fills += 1
        elif txn[1]: self.writes += 1
        else: self.reads += 1

def compare_cached(program, trace_path, icache_bytes, dcache_bytes, enable_init, watch_store=None, checker=None):
    if checker is None: checker = CachedChecker(program, icache_bytes, dcache_bytes, enable_init)
    count = 0
    fields = None
    marks = []
    with Path(trace_path).open() as stream:
        for line in stream:
            if line.strip() == "RESET":
                checker.reset()
                continue
            values = next(csv.reader([line]))
            if fields is None:
                fields = values
                continue
            tag = values[0]
            if tag == "T": checker.start_cycle(int(values[1])); continue
            if tag == "X": checker.irq_record(values[1:]); continue
            if tag == "IQ": checker.fetch_request(values[1:]); continue
            if tag == "IR": checker.fetch_response(values[1:]); continue
            if tag == "Q":
                checker.data_request(values[1:])
                if watch_store and int(values[2], 16) and watch_store(int(values[1], 16), int(values[4], 16)):
                    checker.watch.add(checker.cycle); marks.append(checker.cycle)
                continue
            if tag == "R": checker.data_response(values[1:]); continue
            if tag == "SQ": checker.memory_request(values[1], values[2:]); continue
            if tag == "FI": checker.fence(); continue
            if len(values) != len(fields): raise AssertionError("Malformed trace row")
            decimal = {"order", "rd", "trap", "cause", "intr"}
            actual = {k: int(v, 10 if k in decimal else 16) for k, v in zip(fields, values)}
            actual.setdefault("intr", 0)
            checker.retire(actual, count)
            count += 1
    checker.end_cycle()
    model = checker.model
    if not model.halted: raise AssertionError("Trace ended before terminal diagnostic")
    if checker.issued: raise AssertionError("Data access issued but never retired")
    for master, queue in checker.expected.items():
        if queue: raise AssertionError(f"Predicted {master}-cache memory transactions never issued: {list(queue)[:3]}")
    if read_hex(str(trace_path) + ".mem") != checker.phys:
        raise AssertionError("Final RAM contents differ from independent physical model")
    if checker.phys != model.mem:
        raise AssertionError("Physical RAM differs from architectural memory")
    if read_sdram_dump(str(trace_path) + ".sdram") != dict(checker.phys_sdram.items()):
        raise AssertionError("Final SDRAM contents differ from the independent physical model (data or mapping)")
    if checker.phys_sdram != model.sdram:
        raise AssertionError("Physical SDRAM differs from architectural memory")
    return count, model, checker, [checker.snapshots[c] for c in marks]
