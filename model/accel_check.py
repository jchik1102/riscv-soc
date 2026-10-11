from model.accel_model import AccelModel, BASE as ACCEL_BASE, BYTES as ACCEL_BYTES
from model.cache_check import CachedChecker
from model.rv64i import MAP

INTC = MAP["devices"]["intc"]["base"]
SRC_UART, SRC_ACCEL = MAP["interrupts"]["uart"], MAP["interrupts"]["accelerator"]

def in_accel(address):
    return ACCEL_BASE <= address < ACCEL_BASE + ACCEL_BYTES

class AccelChecker(CachedChecker):
    def __init__(self, program, icache_bytes, dcache_bytes, enable_init, n, parallel):
        self.accel = AccelModel(n, parallel)
        self.accel_accesses = self.accel_errors = self.accel_checked_loads = 0
        self.irq_records = self.external_interrupts = 0
        self.levels = {"accel": 0, "uart": 0, "meip": 0}
        super().__init__(program, icache_bytes, dcache_bytes, enable_init)

    def reset(self):
        super().reset()
        if hasattr(self, "accel"):
            self.accel.reset()
            self.intc_enable = (1 << SRC_UART) | (1 << SRC_ACCEL)
            self.levels = {"accel": 0, "uart": 0, "meip": 0}
            self.external_since_reset = 0
        self.issue_errors = []
        self.last_outcome = None
        self.pending_accel = None
        self._install()

    def _resync(self):
        super()._resync()
        self._install()

    def _install(self):
        checker = self
        def issue(address, size, store, value):
            beat, lane = address & ~7, address % 8
            mask = ((1 << size) - 1) << lane
            error, rdata = checker.accel.access(checker.cycle, beat, store, mask, (value << (8 * lane)) & ((1 << 64) - 1))
            checker.last_outcome = (address, error, rdata, mask, lane, size)
            checker.issue_errors.append((address, error))
            return error
        def retire(address, size, store, value):
            if not checker.issue_errors: raise AssertionError("Accelerator access retired without being issued")
            issued, error = checker.issue_errors.pop(0)
            if issued != address: raise AssertionError(f"Accelerator access order: issued {issued:#x}, retired {address:#x}")
            return error
        if hasattr(self, "ahead"): self.ahead.accel_port = issue
        if hasattr(self, "model"): self.model.accel_port = retire

    def device_request(self, row, write):
        if not in_accel(row["mem_addr"]): return None
        if self.last_outcome is None or self.last_outcome[0] != row["mem_addr"]:
            raise AssertionError("Accelerator request without a model access")
        address, error, rdata, mask, lane, size = self.last_outcome
        self.last_outcome = None
        self.accel_accesses += 1
        if error:
            self.accel_errors += 1
            return (1, 0, None)
        if write: return (0, 0, None)
        insn = row["insn"]
        self.pending_accel = (rdata, mask)
        return (0, None, ((insn >> 7) & 31, (insn >> 12) & 7, address, size))

    def data_request(self, fields):
        address, write, mask, data = (int(x, 16) for x in fields)
        if write and address == INTC + 8 and mask & 1:
            self.intc_enable = data & ((1 << SRC_UART) | (1 << SRC_ACCEL))
        self.pending_intc = None
        if not write and address in (INTC, INTC + 8, INTC + 16):
            pending = (self.levels["uart"] << SRC_UART) | (int(self.accel.irq(self.cycle)) << SRC_ACCEL)
            self.pending_intc = {INTC: pending, INTC + 8: self.intc_enable, INTC + 16: pending & self.intc_enable}[address]
        super().data_request(fields)

    def data_response(self, fields):
        error, rdata = int(fields[0], 16), int(fields[1], 16)
        if self.pending_accel is not None and not error:
            expected, mask = self.pending_accel
            lanes = sum(0xff << (8 * i) for i in range(8) if mask >> i & 1)
            if expected is not None:
                if rdata != expected & lanes:
                    raise AssertionError(f"Accelerator load data {rdata:#018x}, model {expected & lanes:#018x}")
                self.accel_checked_loads += 1
        self.pending_accel = None
        want = getattr(self, "pending_intc", None)
        if want is not None and not error and rdata != want:
            raise AssertionError(f"Interrupt controller register read {rdata:#x}, model {want:#x}")
        self.pending_intc = None
        super().data_response(fields)

    def start_cycle(self, cycle):
        super().start_cycle(cycle)
        if int(self.accel.irq(cycle)) != self.levels["accel"]:
            raise AssertionError(f"Accelerator irq at edge {cycle}: observed {self.levels['accel']}, model {int(self.accel.irq(cycle))}")

    def irq_record(self, fields):
        edge, accel, uart, meip = (int(x) for x in fields)
        self.levels = {"accel": accel, "uart": uart, "meip": meip}
        self.irq_records += 1
        if accel != int(self.accel.irq(edge)):
            raise AssertionError(f"Accelerator irq at edge {edge}: {accel}, model {int(self.accel.irq(edge))}")
        want = (uart and self.intc_enable >> SRC_UART & 1) or (accel and self.intc_enable >> SRC_ACCEL & 1)
        if meip != int(bool(want)): raise AssertionError(f"MEIP {meip} at edge {edge}, interrupt controller model {int(bool(want))}")

    def retire(self, actual, count):
        if actual.get("intr") and actual["cause"] == 11:
            if not self.levels["meip"]: raise AssertionError("Machine external interrupt taken while MEIP is low")
            self.external_interrupts += 1
            self.external_since_reset += 1
        super().retire(actual, count)
