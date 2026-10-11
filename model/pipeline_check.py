import copy
import csv
from collections import deque
from pathlib import Path
from model.rv64i import MAP, MASK, SparseMemory, read_hex, signed
from model.rv64s4 import MachineS4, is_mmio, mmio_register_exists

def _in_ram(address):
    return MAP["ram_base"] <= address <= MAP["ram_base"] + MAP["ram_bytes"] - 8 and address % 8 == 0

SDRAM_BASE, SDRAM_BYTES = MAP["memories"]["sdram"]["base"], MAP["memories"]["sdram"]["bytes"]

def _in_sdram(address):
    return SDRAM_BASE <= address <= SDRAM_BASE + SDRAM_BYTES - 8 and address % 8 == 0

def sdram_offset(bank, row, column, high):
    return (row << 13) | (bank << 11) | (column << 1) | high

def _raw(rdata, address, size):
    return (rdata >> (8 * (address % 8))) & ((1 << (8 * size)) - 1)

class PipelineChecker:
    def __init__(self, program, sdram=False):
        self.phys = bytearray(MAP["ram_bytes"])
        self.phys[:len(program)] = program
        self.phys_sdram = SparseMemory(SDRAM_BYTES) if sdram else None
        self.sdram_accesses = 0
        self.model = MachineS4(bytes(program), sdram=sdram)
        self.fetches = self.accesses = self.mmio_accesses = self.interrupts = self.handled_traps = 0
        self.last_mcycle = None
        self.reset()

    def reset(self):
        self.model.reset()
        self.model.mem = bytearray(self.phys)
        if self.phys_sdram is not None: self.model.sdram = copy.deepcopy(self.phys_sdram)
        self.model.mmio_read = self._mmio_value
        self.mmio_values = deque()
        self._resync()
        self.fetch_out = None
        self.data_out = None
        self.issued = deque()
        self.last_mcycle = None
        self.interrupts_since_reset = 0

    def _resync(self):
        self.ahead = copy.deepcopy(self.model)
        self.ahead.mmio_read = lambda address, size: None
        self.ahead.external = lambda: 0
        self.ahead_mmio = None

    def _mmio_value(self, address, size):
        if not self.mmio_values: raise AssertionError("MMIO load retired without its response")
        return self.mmio_values.popleft()

    def _beat(self, address):
        offset = address - MAP["ram_base"]
        return int.from_bytes(self.phys[offset:offset+8], "little")

    def fetch_request(self, fields):
        address, write, mask, data = (int(x, 16) for x in fields)
        if self.fetch_out is not None: raise AssertionError("Second outstanding fetch")
        if write or mask != 0xff or data or address % 8:
            raise AssertionError(f"Malformed fetch request {fields}")
        self.fetch_out = address
        self.fetches += 1

    def fetch_response(self, fields):
        if self.fetch_out is None: raise AssertionError("Fetch response without request")
        error, rdata = int(fields[0], 16), int(fields[1], 16)
        expected = (0, self._beat(self.fetch_out)) if _in_ram(self.fetch_out) else (1, 0)
        if (error, rdata) != expected:
            raise AssertionError(f"Fetch response at {self.fetch_out:#x}: expected {expected}, actual {(error, rdata)}")
        self.fetch_out = None

    def data_request(self, fields):
        if self.data_out is not None: raise AssertionError("Second outstanding data request")
        while True:
            if self.ahead.halted:
                raise AssertionError("Data request after the predicted terminal diagnostic (extra/wrong-path access)")
            row = self.ahead.step()
            if row["mem_rmask"] or row["mem_wmask"]: break
        write = int(bool(row["mem_wmask"]))
        expected = (row["mem_addr"] & ~7, write, row["mem_wmask"] or row["mem_rmask"], row["mem_wdata"])
        actual = tuple(int(x, 16) for x in fields)
        if actual != expected:
            raise AssertionError(f"Data request for order {row['order']}: expected {expected}, actual {actual}")
        address, _, mask, data = expected
        device = self.device_request(row, write)
        if device is not None:
            self.mmio_accesses += 1
            self.data_out = device
        elif is_mmio(row["mem_addr"]):
            self.mmio_accesses += 1
            if not mmio_register_exists(row["mem_addr"]): self.data_out = (1, 0, None)
            elif write: self.data_out = (0, 0, None)
            else:
                insn = row["insn"]
                self.ahead_mmio = ((insn >> 7) & 31, (insn >> 12) & 7, row["mem_addr"], 1 << ((insn >> 12) & 3))
                self.data_out = (0, None, self.ahead_mmio)
        elif _in_ram(address):
            rdata = 0
            for lane in range(8):
                if mask & (1 << lane):
                    index = address - MAP["ram_base"] + lane
                    if write: self.phys[index] = (data >> (8 * lane)) & 255
                    else: rdata |= self.phys[index] << (8 * lane)
            self.data_out = (0, rdata, None)
        elif self.phys_sdram is not None and _in_sdram(address):
            rdata = 0
            for lane in range(8):
                if mask & (1 << lane):
                    index = address - SDRAM_BASE + lane
                    if write: self.phys_sdram[index:index+1] = bytes([(data >> (8 * lane)) & 255])
                    else: rdata |= self.phys_sdram[index:index+1][0] << (8 * lane)
            self.data_out = (0, rdata, None)
            self.sdram_accesses += 1
        else:
            self.data_out = (1, 0, None)
        self.issued.append([row["order"], False])
        self.accesses += 1

    def device_request(self, row, write):
        return None

    def data_response(self, fields):
        actual = tuple(int(x, 16) for x in fields)
        if self.data_out is None: raise AssertionError(f"Data response without request: {actual}")
        error, rdata, load = self.data_out
        if load is not None:
            if actual[0] != 0: raise AssertionError(f"MMIO load to an existing register returned an error")
            rd, f3, address, size = load
            raw = _raw(actual[1], address, size)
            if actual[1] & ~(((1 << (8 * size)) - 1) << (8 * (address % 8))) & MASK:
                raise AssertionError("MMIO response data outside the selected lanes")
            self.mmio_values.append(raw)
            value = signed(raw, size * 8) if f3 < 4 else raw
            if rd: self.ahead.regs[rd] = value & MASK
            self.ahead_mmio = None
        elif actual != (error, rdata):
            raise AssertionError(f"Data response expected {(error, rdata)}, actual {actual}")
        self.issued[-1][1] = True
        self.data_out = None

    def retire(self, actual, count):
        external_used = []
        def external():
            external_used.append(actual["rd_data"])
            return actual["rd_data"]
        self.model.external = external
        if actual.get("intr"):
            if self.issued: raise AssertionError("Interrupt taken with a data access outstanding")
            if not self.model.interrupts_enabled(actual["cause"]):
                raise AssertionError(f"Interrupt {actual['cause']} taken while not enabled")
            expected = self.model.take_interrupt(actual["cause"])
            self.interrupts += 1
            self.interrupts_since_reset += 1
        else:
            expected = self.model.step()
        if actual != expected:
            differences = {k: (expected.get(k), actual.get(k)) for k in expected if expected.get(k) != actual.get(k)}
            raise AssertionError(f"Trace row {count}: expected/actual {differences}")
        if expected["trap"] and not self.model.halted and not expected.get("intr"): self.handled_traps += 1
        if external_used:
            name = self.model.last_name
            csr = (expected["insn"] >> 20)
            if csr == 0xB00:
                if self.last_mcycle is not None and actual["rd_data"] < self.last_mcycle:
                    raise AssertionError("mcycle decreased")
                self.last_mcycle = actual["rd_data"]
            elif csr == 0x344 and actual["rd_data"] & ~0x888:
                raise AssertionError("mip shows an unimplemented interrupt bit")
        if expected["mem_rmask"] or expected["mem_wmask"]:
            if not self.issued or self.issued[0][0] != expected["order"]:
                raise AssertionError(f"Memory instruction {expected['order']} retired without its own data request")
            if not self.issued[0][1]:
                raise AssertionError(f"Memory instruction {expected['order']} retired before its response")
            self.issued.popleft()
        elif self.issued and self.issued[0][0] <= expected["order"]:
            raise AssertionError("Issued data access was skipped at retirement")
        if (external_used or expected.get("intr") or expected["trap"]) and not self.issued and self.data_out is None:
            self._resync()

def read_sdram_dump(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line.strip():
            bank, row, column, high, value = line.split()
            result[sdram_offset(int(bank), int(row), int(column), int(high))] = int(value, 16)
    return result

def compare_pipeline(program, trace_path, sdram=False):
    checker = PipelineChecker(program, sdram)
    count = 0
    fields = None
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
            if tag == "IQ": checker.fetch_request(values[1:]); continue
            if tag == "IR": checker.fetch_response(values[1:]); continue
            if tag == "Q": checker.data_request(values[1:]); continue
            if tag == "R": checker.data_response(values[1:]); continue
            if len(values) != len(fields): raise AssertionError("Malformed trace row")
            decimal = {"order", "rd", "trap", "cause", "intr"}
            actual = {k: int(v, 10 if k in decimal else 16) for k, v in zip(fields, values)}
            actual.setdefault("intr", 0)
            checker.retire(actual, count)
            count += 1
    model = checker.model
    if not model.halted: raise AssertionError("Trace ended before terminal diagnostic")
    if checker.issued: raise AssertionError("Data access issued but never retired")
    if not checker.fetches: raise AssertionError("Missing accepted fetch transactions")
    if read_hex(str(trace_path) + ".mem") != checker.phys:
        raise AssertionError("Final RAM contents differ from independent physical model")
    if checker.phys != model.mem:
        raise AssertionError("Physical RAM differs from architectural memory")
    if sdram:
        if read_sdram_dump(str(trace_path) + ".sdram") != dict(checker.phys_sdram.items()):
            raise AssertionError("Final SDRAM contents differ from the independent physical model (data or mapping)")
        if checker.phys_sdram != model.sdram:
            raise AssertionError("Physical SDRAM differs from architectural memory")
    return count, model, checker
