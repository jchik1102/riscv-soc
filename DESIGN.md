# Design decisions

> **How to read this.** Each entry states what the RTL does, with file
> references, and then answers the design questions. The answers were
> **inferred from the code, tests and logs**, not taken from the author's
> notes, so they explain why the design works as it does, not a recorded
> history of the decision. Where the repository holds no evidence (for
> example, whether an alternative was measured first), the answer says so.

## 1. Branches resolve in EX; fetch follows a BHT/BTB prediction

**What the RTL does.** Branch conditions are evaluated in EX on the forwarded
operands (`rtl/core/core_pipeline.sv:196-204`, operands from `:150`). Fetch
looks up `pc_f` in `branch_predictor` (`:434`) in the same cycle: a 32-entry
direct-mapped BTB with 8-bit partial tags and a table of 256 two-bit
counters. A BTB hit predicts the stored target for JAL, and for a branch when
its counter says taken (`:456`); otherwise fetch continues at pc+4 (`:311`,
`:368`). The predicted next PC travels with the instruction; ID compares it
with pc+4 and pc+imm (`:294`), and EX redirects only when the prediction was
wrong (`:298-304`). A redirect loads the real next PC (`:367`) and flushes IF
and ID (`flush_front`, `:316`, `:372`, `:382`), discarding the two younger
instructions, and is counted by `event_redirect` (`:336`). JALR, MRET and
FENCE.I always redirect. The predictor is trained from EX on branches and
JAL, and clears on reset.

**Why EX rather than ID?** In EX the comparator sits behind the existing
forwarding muxes (`fa`/`fb`), so a branch can use a result produced by the
instruction directly ahead of it with no extra hazard logic. Resolving in ID
would need a second forwarding path into ID and a stall whenever a branch
depends on an instruction still in EX.

**Why a predictor, and what did it change?** Before prediction every taken
branch or jump cost two fetched instructions. CoreMark on the core
(`make coremark`, 10 iterations, memory answering one cycle after each
request) went from 0.894 to 0.971 CoreMark/MHz, and its misprediction rate
(new perf counters for control transfers and mispredictions, offsets 0x78
and 0x80) fell from 60.25% to 15.17%. On the S3 FIR benchmark the rate fell
from 54.76% to 4.34% and cycles by 6.4%
([summary](results/coremark/summary.txt)). The gain is smaller than the
redirect reduction because the bus allows one outstanding fetch and one data
request, so memory waits dominate (IPC 0.350 with prediction). CoreMark's
own CRCs check that both runs computed correctly.

**Why is a misprediction always safe?** EX checks every instruction's next PC
against the prediction, not just control transfers. A partial-tag alias that
predicts a jump at a non-branch, or a stale target, is caught the same way as
a wrong direction, so the predictor can only cost cycles. The full
regression, the 23 pipeline mutants and the UVM runs pass with it.

**Why are the comparisons in ID, and why is JALR not predicted?** The first
version compared the 64-bit real next PC with the prediction in EX. That put
a 64-bit compare after the forwarded branch compare, and the S8 build missed
50 MHz by 0.053 ns (slow 85 °C) on the path into the redirect perf counter
([worst paths](results/quartus/bpred-first-version/worst_setup_paths.txt)).
Comparing the prediction with pc+4 and pc+imm in ID, where neither depends on
forwarded operands, leaves EX with a one-bit select on the branch outcome. A
JALR target needs a forwarded register and an adder, so JALR keeps its
unconditional redirect; with no return-address stack most JALRs (returns)
would mispredict anyway. The first version, which also predicted JALR,
measured 0.978 CoreMark/MHz
([summary](results/coremark/first-version/summary.txt)), within 1% of the
final design.

**What did it cost on the FPGA?** The S8 build, with the predictor and the two
new counters, closes at 50 MHz with +0.377 ns of setup slack (it had +1.546 ns
without prediction) and uses 25,364 logic elements, up from 21,517 ([fit](results/quartus/de10_lite_s8_p1.fit.summary),
[timing](results/quartus/de10_lite_s8_p1.sta.summary)). The BTB and counters
are flip-flops because the lookup has to be combinational in the fetch cycle,
and the MAX 10's M9K blocks only have registered reads.

## 2. Iterative multiply/divide unit instead of hard multipliers

**What the RTL does.** All 13 M instructions go through `muldiv_unit`, built on
`mul_iter` and `div_iter`. The multiplier is shift-and-add, one bit per cycle,
64 iterations (32 for the W forms) with a sign correction term
(`rtl/core/mul_iter.sv:22-23`, `:51`). The divider is a restoring
shift-subtract on magnitudes, one quotient bit per cycle, with signs fixed at
the end (`rtl/core/div_iter.sv`). The pipeline stalls while the unit is busy
(`event_arith_wait`).

**Why not the MAX 10's 9-bit hard multipliers?** A 64x64 multiply built from
9-bit elements needs dozens of them plus a wide adder tree that would be hard
to close at 50 MHz in one cycle, and a divide can't use them at all. One
iterative datapath serves both operations in small area. The 16 multiplier
elements the S8 build does use belong to the 4x4 accelerator's parallel MACs
([fit summary](results/quartus/de10_lite_s8_p1.fit.summary)).

**Why radix-2, with no early-out?** It is the simplest correct structure:
each step is one add or subtract and one shift, and the latency is fixed (65
cycles, 33 for the W forms), which keeps the pipeline stall logic and the
Python cycle model simple. Radix-4 or an early-out would roughly halve the
latency at the cost of more logic and data-dependent timing.

**Divide-by-zero and `MIN / -1`.** Divide-by-zero returns an all-ones quotient
(`div_iter.sv:35`) and the dividend as remainder, as the ISA specifies.
`MIN / -1` needs no special case: the magnitude of `MIN` is 2^63, the
quotient magnitude is 2^63, and negating it gives `MIN` back with remainder 0,
which is the specified result. Both are checked by the M-unit bench vectors
(`scripts/muldiv_vectors.py`) and by the 12 M-unit mutants, which include a
negated divide-by-zero quotient (`results/checkers/muldiv_mutants.json`).

## 3. Forwarding priority and the load-use stall

**What the RTL does.** EX operands take the MEM-stage result first, then the
WB-stage result, then the register file (`core_pipeline.sv:131-136`). MEM
forwarding is disabled for loads (`mem_fwd`, `:124`), so a dependent
instruction behind a load stalls one cycle (`event_load_use`, `:297`). ID also
reads through a WB bypass (`:118-120`), so the register file needs no
write-before-read timing.

**Why MEM before WB?** When both stages hold the same `rd`, MEM holds the
younger write, which is the value program order says the reader should see.
Giving WB priority would forward a stale value.

**Why no load forwarding from MEM?** Load data arrives from the bus response
during MEM. Forwarding it into EX in the same cycle would chain the bus
response, the load alignment and sign-extension (`load_store`) and the ALU
into one path. Stalling one cycle keeps that path out of the critical timing
at the cost of one cycle per back-to-back load use, which the
`event_load_use` counter measures.

**Why `rd != 0` and `!trap`?** `x0` is hardwired to zero, so a write to it
must never be forwarded. An instruction that trapped never architecturally
writes its `rd`, so forwarding its result would leak a value that doesn't
exist.

## 4. Write-through, direct-mapped 2 KiB caches with 32-byte lines

**What the RTL does.** The I- and D-caches are instances of one `cache` module
(`rtl/memory/cache.sv`, `LINE_BYTES = 32`, `:25`). The D-cache is
write-through (`WRITES(1)`, `rtl/soc/cpu_soc.sv:111`). Both refill through
`burst_arbiter` into the SDRAM controller (`cpu_soc.sv:118`).

**Why write-through?** With one core and no other bus master writing SDRAM,
write-through needs no dirty bits, no write-back buffer and no eviction path.
SDRAM always holds current data, so software can turn the D-cache off through
the cache control registers at any time without a flush. Disabling it clears
every valid bit (`rtl/memory/cache.sv:172`), so re-enabling starts cold and
can't return stale lines. The cost is SDRAM
traffic on every store.

**Why direct-mapped, 2 KiB?** Direct-mapped is the smallest correct cache: one
tag compare and no replacement state. The size is set by
`CACHES_ICACHE_BYTES`/`CACHES_DCACHE_BYTES` in `config/address_map.json`. The
repository doesn't record why 2 KiB was chosen. The S8 build uses 38% of the
device's memory bits, most of it the 64 KiB on-chip RAM.

**I-cache coherence with stores to code.** It isn't automatic. Software must
execute FENCE.I. In EX, FENCE.I waits until older instructions have drained
(`fence_wait`, `core_pipeline.sv:270`), invalidates the I-cache
(`icache_inv`, `:271`) and drops the fetch buffer (`:327`), so instructions
fetched after it see the new code. This is what Zifencei requires.

## 5. Data port wins arbitration for the shared on-chip RAM

**What the RTL does.** Fetch and data share the single-ported `onchip_ram`
through `bus_arbiter`. Fetch (`m1`) is granted only when the data port (`m0`)
has no request (`rtl/soc/bus_arbiter.sv:24`). A lock keeps the owner for a
multi-beat transaction (`:40-42`).

**Why data first?** A data access comes from the instruction in MEM, the
oldest instruction in flight. Serving it first lets that instruction retire
and frees the pipeline. Stalling it to fetch younger instructions that can't
make progress anyway would only add cycles.

**Can fetch starve?** No. Each MEM instruction issues at most one data
request. While it waits, nothing new enters MEM, so the data port goes idle
and fetch is granted. Forward progress is checked by the trace runs with
random bus delays (`MaxDelay` up to 9) and by the UVM random tests.

**Why one RAM port?** The on-chip RAM is also the target of the boot loader
port, and a second CPU port would need dual-port M9K configuration and
duplicated address decode. The repository doesn't record whether dual-port
was tried. With the caches in S6 and later, code in SDRAM is fetched through
the I-cache, which removes most of the contention.
