# RV64IM system on the DE10-Lite

[![CI](https://github.com/jchik1102/riscv-soc/actions/workflows/ci.yml/badge.svg)](https://github.com/jchik1102/riscv-soc/actions/workflows/ci.yml)

An original SystemVerilog RISC-V system for the Terasic DE10-Lite (MAX 10 `10M50DAF484C7G`) at 50 MHz. Its main core is a five-stage pipeline (IF/ID/EX/MEM/WB, with forwarding, load-use and M-unit stalls, and BHT/BTB branch prediction with a return-address stack in fetch) implementing RV64IM_Zicsr_Zifencei in machine mode with traps, MRET and timer, software and external interrupts. The original multicycle RV64IM core is kept as a reference configuration. Around the core are an iterative multiply/divide unit, 2 KiB direct-mapped I- and D-caches over an SDR SDRAM controller for the board's 64 MiB chip, MMIO UART, timer, 16 performance counters (including resolved control transfers and mispredictions), cache control, an interrupt controller, and a 4x4 INT8 matrix multiply-accumulate accelerator with a completion interrupt. Verification never takes expected values from the RTL. A Python ISA/system model fetches and decodes every program on its own, Spike runs the same bytes, a UVM 1.2 testbench in XSim drives random and directed programs, riscv-formal checks the pipeline's instructions to a bounded depth, and every checker was shown to work by injecting bugs into the RTL and the traces.

![Block diagram](docs/block_diagram.svg)

The diagram is an SVG with the draw.io model embedded; open `docs/block_diagram.svg` in draw.io to edit it.

**Demo video:** _placeholder — link to be added._

## Tools

| Tool | Version | Used for |
| --- | --- | --- |
| Quartus Prime Lite | 24.1std.0, MAX 10 device support, USB-Blaster driver | FPGA build and programming (Windows) |
| Vivado XSIM | 2025.2 with UVM 1.2 | RTL and UVM simulation (Windows) |
| Questa Intel Starter FPGA Edition | 2024.3, from the Quartus 24.1std download, free licence | `make questa`, the directed benches in a second simulator (Windows) |
| Vivado | 2025.2 with Artix-7 device support | `make vivado`, implementation for a Xilinx part (Windows) |
| WSL Ubuntu | 24.04 | firmware, Python, Spike, `make` |
| riscv64-unknown-elf-gcc | 13.2.0 | firmware |
| Python | 3.12 venv at `/home/jonat/.venvs/riscv-soc` with `requirements-lock.txt` | models, checkers, tests |
| Perl | 5.38 (Ubuntu's, core modules only) | `make questa`'s trace comparison with XSim |
| Spike | commit in `spike-commit.txt` | reference simulator |
| riscv-formal | YosysHQ commit `c992aa6`, cloned to `~/hwtools/riscv-formal` (or set `RVF`) | `make riscv-formal` |
| PowerShell | 7 (`pwsh.exe`) for the Makefile; the scripts also run in Windows PowerShell | driving XSim and Quartus |

The scripts default to `C:\intelFPGA_lite\24.1std\quartus`, `C:\AMDDesignTools\2025.2\Vivado`, WSL distro `Ubuntu` and the venv above. Pass `-Quartus`, `-Vivado`, `-Distro` or `-LinuxPython` to override them. The Makefile uses `pwsh.exe` from `PATH`, or set `PWSH=/path/to/pwsh.exe`.

## Running it

| Command (WSL, repository root) | What it runs |
| --- | --- |
| `make models` | Python model and checker tests |
| `make test` | `scripts/regress.ps1` (everything except UVM and board builds, ends `REGRESSION_PASS`), then `scripts/regress_uvm.ps1` (UVM regression with Python/Spike re-checks, ends `UVM_REGRESSION_PASS`), then `make results` |
| `make fpga` | `scripts/build_board.ps1 -Stage s8 -Demo s8 -Power`: full Quartus compile and vectorless power estimate, then `make results` |
| `make fpga-synth` | `scripts/synthesize.ps1 -Stage s8 -Pipeline 1 -AccelN 4`: exact-device synthesis check |
| `make vivado` | `scripts/run-vivado.ps1`: Vivado out-of-context synthesis, placement and routing of the `fpga-synth` configuration for a Xilinx Artix-7 at 50 MHz, reports in `results/vivado/`; see [Vivado implementation](#vivado-implementation-for-a-xilinx-part) |
| `make program` | `scripts/program_board.ps1 -Stage s8` (board connected, all switches down) |
| `make results` | `scripts/collect_results.py`: copies the logs and reports that back this README into `results/` |
| `make act` | riscv-arch-test (ACT4) RV64I and RV64M on the pipeline core, plus the same ELFs on Spike; see [Compliance and random testing](#compliance-and-random-testing) |
| `make riscvdv INSTR_CNT=300` | riscv-dv random programs on the pipeline core and Spike, each checked against the Python model |
| `make coremark` | CoreMark (10 iterations) and the S3 FIR benchmark on the pipeline core, with full prediction, without JALR prediction and without prediction; see [Branch prediction, CoreMark and FIR](#branch-prediction-coremark-and-fir) |
| `make formal` | SymbiYosys checks of the M unit (`formal/`); needs OSS CAD Suite with the yosys-slang plugin in WSL (the 2026-10-14 build was used, versions in [versions.txt](results/formal/versions.txt)). See [Formal checks of the M unit](#formal-checks-of-the-m-unit) |
| `make riscv-formal` | riscv-formal checks of the pipeline core through its RVFI port (`formal/rvfi/`), with the same OSS CAD Suite; `make riscv-formal-mutants` runs them on RTL mutants. See [riscv-formal on the pipeline core](#riscv-formal-on-the-pipeline-core) |
| `make fir` | The hardware FIR filter: MATLAB (R2026a, Fixed-Point Designer's `fi`) regenerates the expected outputs, which must equal `tests/fir/`; the unit bench at 1, 2, 4, 8 and 16 lanes; the ADC-model bench and MATLAB's analysis of it; the mutants. `make test` runs the same benches without MATLAB, on the committed vectors. See [Hardware FIR filter](#hardware-fir-filter-matlab-model-and-adc-model) |
| `make fir-synth` | The FIR filter alone in Quartus (MAX 10) and Vivado (Artix-7) at 50 MHz, with 1, 4 and 16 lanes |
| `make ddr3` | DDR3 in simulation: the bridge bench through Xilinx's MIG and Micron's DDR3 model, the same bench on the SDR path, then S6 cache programs on DDR3. See [DDR3](#ddr3-through-xilinxs-mig-simulated-and-implemented) |
| `make arty` | Vivado implementation of the Arty A7-100T board top with DDR3, to a bitstream (never run on a board) |
| `make questa` | The directed benches in Questa: unit benches, both cores' trace matrices (checked by the model, then compared file for file with XSim's from `make test-sim`) and the integration benches. See [Second simulator: Questa](#second-simulator-questa) |

`regress.ps1` builds the firmware itself. Run XSIM jobs one at a time; parallel XSIM runs in the same folder interfere. The same scripts can be run directly from PowerShell, for example `.\scripts\regress.ps1`.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request, on GitHub's Ubuntu runners: the Python model and checker tests, a Verilator lint of the pipeline core, and `scripts/run-formal.sh` (the M-unit SymbiYosys checks, with the same OSS CAD Suite build as above). Everything that needs XSim or Quartus (`make test`, `act`, `riscvdv`, `coremark`, `fpga`) cannot run there and is run locally; its logs are committed under `results/`.

### On the board

1. Build the firmware images (`make test` does this too):

   ```powershell
   wsl -d Ubuntu --cd /mnt/c/projects/riscv-soc --exec /home/jonat/.venvs/riscv-soc/bin/python scripts/programs.py
   ```

2. Build the FPGA image with `make fpga`. It writes `build/quartus_board_s8_p1/output_files/de10_lite_s8_p1.sof`.
3. Connect the DE10-Lite over USB, put all switches down, and run `make program`. Programming is over JTAG and is lost at power-off. The script prints "Configuration succeeded".

The demo starts by itself; KEY0 reruns it. Switches are written SW9 ... SW0, and up = 1. LEDR0 on with LEDR1 off means the demo passed its own checks; LEDR4 = SDRAM ready, LEDR6 = caches built, LEDR7 = accelerator built, and LEDR9 blinks. SW1 SW0 select the HEX view: `0 0` shows the checksum of all results, `1 1` the accelerator case and mismatch counts, `0 1` the phase and the number of 1 ms timer interrupts taken, and `1 0` cycle counts. With `1 0`, SW5 to SW8 pick which measurement is shown (CPU or accelerator, polled or interrupt-driven, caches on or off, the 16x16 product or the 64 small cases), and SW4 SW3 SW2 show the other counters: cycles, retired instructions, memory waits, M-unit cycles, D-cache accesses and misses, uncached loads and SDRAM stores.

Earlier stage demos are built and programmed the same way with `build_board.ps1 -Stage sN -Demo <demo>` and `program_board.ps1 -Stage sN`: `-Stage s3 -Demo fir` (FIR benchmark), `-Stage s4 -Demo s4` (timer interrupts), `-Stage s5 -Demo s5` (test of all 64 MiB of SDRAM; SW9 up at KEY0 runs the hardware tester), `-Stage s6 -Demo s6` (caches) and `-Stage s7 -Demo s7` (accelerator).

## Address map

| Region | Base | Size |
| --- | --- | --- |
| On-chip RAM (reset PC) | 0x8000_0000 | 64 KiB |
| SDRAM (cacheable; DDR3 on the Arty top) | 0x9000_0000 | 64 MiB |
| UART | 0x1000_0000 | 256 B |
| Timer (MSIP, MTIMECMP, MTIME) | 0x1000_1000 | 256 B |
| Performance counters | 0x1000_2000 | 256 B |
| Cache control | 0x1000_3000 | 256 B |
| Interrupt controller | 0x1000_4000 | 256 B |
| Matrix accelerator | 0x1001_0000 | 64 KiB |
| FIR filter (`dsp`, when `FIR_LANES` is set) | 0x1002_0000 | 64 KiB |

The map is defined in `config/address_map.json`; `scripts/gen_map.py` generates `rtl/soc/platform_pkg.sv` and `sw/platform.h` from it.

## Results

Every number below comes from a log in [`results/`](results/), produced by `make test`, `make fpga`, `make formal` (`results/formal/`) and `make riscv-formal` (`results/riscv-formal/`). [`results/summary.txt`](results/summary.txt) records the commit and date, and holds the totals that `scripts/collect_results.py` derives from the logs.

**Verification**

| Check | Result | Log |
| --- | --- | --- |
| Python model and checker tests | 240 passed | [test-sim.log](results/test-sim.log) |
| Multicycle CPU traces | 132 traces, 38,972 retired instructions checked | [test-sim.log](results/test-sim.log), [trace_results.json](results/checkers/trace_results.json) |
| Pipeline CPU traces (random interrupts and resets) | 248 traces, 92,699 retired instructions checked | [test-sim.log](results/test-sim.log), [trace_results_pipeline.json](results/checkers/trace_results_pipeline.json) |
| Multicycle vs pipeline | 80 programs, 29,793 identical retirements | [core_comparison.json](results/checkers/core_comparison.json) |
| Spike comparison | 94 programs agree; 2 skipped by design (WFI is a no-op here; SDRAM instruction fetch faults here) | [summary.txt](results/summary.txt), [test-sim.log](results/test-sim.log) |
| RTL mutants | 97 of 97 detected (M unit 12, pipeline 23, SDRAM 23, cache 17, accelerator 22) | [summary.txt](results/summary.txt), [checkers/](results/checkers/) |
| Trace fault injection | 16 multicycle and 8 pipeline corruptions detected | [fault_injection.json](results/checkers/fault_injection.json) |
| SoC firmware and random whole-system runs | S4 to S8 retirements checked record by record; per-stage run and retirement totals in the summary | [summary.txt](results/summary.txt) |
| UVM 1.2 | 106 runs, 0 UVM errors; 163 transcripts (68,048 records) re-checked by Python and Spike | [summary.txt](results/summary.txt), [test-uvm.log](results/test-uvm.log) |
| UVM functional coverage (merged) | Pipeline: 100% of defined bins. Multicycle: 62.97%. The covergroups are shared, and the multicycle core cannot hit the pipeline-only bins (load-use, redirect, fetch-wait, second bus port); its trap-cause bins are also only partly hit | [pipeline](results/uvm/coverage_pipeline.txt), [multicycle](results/uvm/coverage_multicycle.txt) |
| UVM code coverage (XSim, merged over the 106 runs; testbench excluded) | Pipeline core: statements 569/583 (97.60%), branches 332/343 (96.79%), conditions 315/326 (96.63%). Multicycle core: 337/358 (94.13%), 202/216 (93.52%), 172/196 (87.76%). What is left: interrupt entry, because the UVM bench ties the interrupt inputs to 0 (interrupts are tested by `pipe_tb` and the SoC benches, which do not collect code coverage); a write to `mcycle`; ECALL, MRET, WFI and CSR decoding on the multicycle core, whose UVM list has no such program; and `default` arms that no encoding reaches. Toggle coverage is left out because Vivado 2025.2's report tool crashed on 10 of 11 attempts to report it | [pipeline](results/uvm/code_coverage_pipeline.txt), [multicycle](results/uvm/code_coverage_multicycle.txt), [toggle crash](results/uvm/xcrg_toggle_crash.txt) |

**Simulation of the board demos** ([test-sim.log](results/test-sim.log), `BOARD_TB_PASS` lines): the S3 FIR benchmark gives checksum `c6e755` in 103,387 cycles on the pipeline (109,067 before branch prediction, [baseline](results/baseline/test-sim-before-bpred.log)) and 154,346 cycles on the multicycle core, both retiring 18,009 instructions.

**FPGA build (S8, Quartus Prime Lite 24.1, `make fpga`):**

| Measurement | Result | Report |
| --- | --- | --- |
| Logic elements | 25,898 / 49,760 (52%) | [fit.summary](results/quartus/de10_lite_s8_p1.fit.summary) |
| Memory bits | 629,696 / 1,677,312 (38%) | [fit.summary](results/quartus/de10_lite_s8_p1.fit.summary) |
| 9-bit multipliers, PLLs | 16 / 288, 1 / 4 | [fit.summary](results/quartus/de10_lite_s8_p1.fit.summary) |
| Worst setup slack, 50 MHz core clock | +0.487 ns (slow 85 °C) | [sta.summary](results/quartus/de10_lite_s8_p1.sta.summary) |
| Worst hold slack, core clock | +0.146 ns (fast 0 °C) | [sta.summary](results/quartus/de10_lite_s8_p1.sta.summary) |
| Fmax, core clock | 51.25 MHz (slow 85 °C) | [sta.rpt](results/quartus/de10_lite_s8_p1.sta.rpt) |
| Power | 463.77 mW total thermal; vectorless estimate with low confidence, not a measurement | [pow.summary](results/quartus/de10_lite_s8_p1.pow.summary) |

All reported setup, hold and pulse-width checks in all three corners have positive slack.

### Vivado implementation for a Xilinx part

`make vivado` builds the `make fpga-synth` configuration ([`fpga/de10_lite/synthesis_top.sv`](fpga/de10_lite/synthesis_top.sv): pipeline core, M unit, 64 KiB on-chip RAM, peripherals and the 4x4 accelerator, without the board's PLL and I/O) with Vivado 2025.2 for an Artix-7 xc7a100tcsg324-1, out of context, at 50 MHz: synthesis, placement, physical optimization and routing ([`scripts/vivado-impl.tcl`](scripts/vivado-impl.tcl), log [vivado.log](results/vivado.log)). It checks that the RTL is not tied to Quartus and meets timing with a second vendor's tools. Nothing was run on Xilinx hardware. Fmax is 1000 / (period − worst slack).

| Measurement | Result | Report |
| --- | --- | --- |
| Slice LUTs | 12,664 / 63,400 (20.0%); core 10,446, accelerator 1,564 | [utilization.txt](results/vivado/utilization.txt), [by module](results/vivado/utilization_hierarchy.txt) |
| Slice registers | 9,555 / 126,800 (7.5%) | same |
| Block RAM tiles | 16 / 135 (the on-chip RAM, eight 8K x 8 byte lanes) | same |
| DSP48E1 | 0 / 240: Vivado built the accelerator's sixteen 8x8 products from LUTs | same |
| Worst setup slack, 50 MHz | +1.962 ns (55.44 MHz) | [timing_summary.txt](results/vivado/timing_summary.txt), [worst path](results/vivado/worst_setup_path.txt) |
| Worst hold slack | +0.079 ns | same |
| Unrouted nets | 0 | [result.txt](results/vivado/result.txt) |

### Compliance and random testing

**riscv-arch-test.** The current framework is ACT4, which replaced RISCOF: it builds self-checking ELFs whose expected values come from the Sail reference model (0.15) at build time, so there is no signature dump. The configuration in [`compliance/act4/riscv-soc-rv64im/`](compliance/act4/riscv-soc-rv64im/) declares I, M, Zicsr, Zifencei and Sm, trapping misaligned accesses and direct-mode `mtvec`, with privileged tests off. Each test ends by writing `tohost`, clearing `mtvec` and executing `ECALL`, which halts the core; [`scripts/act_check.py`](scripts/act_check.py) reads `tohost` from the testbench's final memory dump. The images need up to 148,256 bytes ([manifest](results/act4/manifest.json)), so these runs compile `pipe_tb` with a **256 KiB testbench memory** (`+define+TB_MEM_BYTES`); the RTL, the SoC and every other run keep the 64 KiB on-chip RAM, so these tests could not run from the board's memory. ACT4 requires GCC 15 or later, so the ELFs are built with GCC 16.1 (riscv-gnu-toolchain 2026.08.27); the firmware still uses GCC 13.2.

| Check | Result | Log |
| --- | --- | --- |
| ACT4 on the pipeline core (XSim) | RV64I 51 of 51, RV64M 13 of 13 | [rtl.log](results/act4/rtl.log), [rtl.csv](results/act4/rtl.csv) |
| Same ELFs on Spike | 64 of 64 | [spike.log](results/act4/spike.log), [spike.csv](results/act4/spike.csv) |
| ACT4 against pipeline RTL mutants | 6 of 6 detected: `sub_computes_add` 0 of 64 pass, `branch_target_off_by_four` 0 of 64, `no_mem_to_ex_forwarding` 0 of 64, `m_operand_b_takes_rs1` 51 of 64, `word_alu_not_sign_extended` 55 of 64, `load_word_zero_extended` 63 of 64 (only `I-lw-00` catches it) | [mutant logs](results/act4/), e.g. [rtl-mut_load_word_zero_extended.csv](results/act4/rtl-mut_load_word_zero_extended.csv) |

**riscv-dv.** Random programs come from riscv-dv's Python generator (pyflow) with a custom `rv64im` target ([`compliance/riscv-dv/rv64im/`](compliance/riscv-dv/rv64im/)): no C extension, misaligned accesses trap, direct-mode `mtvec`, and only the CSRs the core implements. Each program is checked twice against the independent Python model: the RTL trace by the existing pipeline checker (`scripts/check_pipeline_trace.py`), and Spike's commit log by the existing `scripts/spike_compare.py`. A program passes only if both agree with the model.

| Run | Programs | Result | Log |
| --- | --- | --- | --- |
| 300 instructions per test | 16 requested; 13 generated (`loop` and one `rand_instr` timed out in the generator), 2 rejected as invalid assembly (see below) | 11 of 11 pass on the RTL and on Spike; 3,155 Spike-matched register commits | [rtl.log](results/riscv-dv/n300/rtl.log), [results.json](results/riscv-dv/n300/results.json), [gen.log](results/riscv-dv/n300/gen.log) |
| 2,000 instructions per test | 16 requested; 13 generated (`loop` and one `rand_instr` timed out in the generator), 3 rejected as invalid assembly | 10 of 10 pass on the RTL and on Spike; 6,604 Spike-matched register commits | [check.log](results/riscv-dv/n2000/check.log), [results.json](results/riscv-dv/n2000/results.json), [gen.log](results/riscv-dv/n2000/gen.log) |

**Most programs end early.** All but one of the programs that use pyflow's load/store streams take an unexpected load or store exception (address misaligned or access fault, causes 4 to 7) between their 86th and 241st retired instruction, although the target declares misaligned accesses unsupported; riscv-dv's handler then dumps the registers and ends the test. The exception is `riscv_no_fence_test_1` at 300 instructions, which ran to its normal end. The RTL, Spike and the model agree on all of it, but those programs only exercise about 100 to 240 random instructions plus the trap path. Only the arithmetic, jump-stress and loop programs, which have no load/store streams, run to their normal end: up to 2,155 retired instructions at 2,000. No program reached one of its illegal instructions before ending. The retired count and trap positions of every program are in its `results.json`.

What differs from a standard riscv-dv run, and why (all recorded in [`testlist.yaml`](compliance/riscv-dv/rv64im/testlist.yaml)):

- riscv-dv's pyflow imports `imp`, which Python 3.12 removed. [`compliance/riscv-dv/patches/0001-python312-importlib-reload.patch`](compliance/riscv-dv/patches/0001-python312-importlib-reload.patch) changes that one import to `importlib`; `scripts/riscvdv_gen.sh` applies it.
- pyflow crashes with any sub-program (`callstack_gen` is missing), so every test runs with `+num_of_sub_program=0`: there are no calls and returns between sub-programs.
- `riscv_rand_instr_test.py` overwrites its options in code and hits that crash, so `no_fence` and `illegal_instr` run through `riscv_instr_base_test` with the same options and streams.
- pyflow does not implement `riscv_hazard_instr_stream`, `riscv_multi_page_load_store_instr_stream` or `riscv_mem_region_stress_test`; they are replaced by the load/store streams it does have.
- Not run: `riscv_ebreak_test` (pyflow cannot generate EBREAK), `riscv_hint_instr_test` (pyflow emits only compressed HINTs; there is no C extension), and the debug-mode, interrupt, unaligned, PMP and CSR tests (features the core does not have).
- pyflow sometimes emits invalid assembly (`la zero, ...`, or `slti zero,zero,none`); such programs are counted as not run, not as passes.
- `illegal_instr_ratio` is per 1000 main-program instructions, so the 300-instruction programs contain at most one: `riscv_illegal_instr_test_1` has one (`kIllegalFunc7`, [source](results/riscv-dv/n300/riscv_illegal_instr_test_1.S)) and ends at a load fault before reaching it.
- Generated programs are changed in two places by [`scripts/riscvdv_prepare.py`](scripts/riscvdv_prepare.py): `csrw mtvec, zero; ecall` is added after the `tohost` store so the core halts, and riscv-dv's fixed 5000-word user and kernel stacks are cut to 1024 words so a program fits the 64 KiB RAM.

### Formal checks of the M unit

`make formal` checks `muldiv_unit` (the iterative multiplier and divider used by both cores) against a reference written from the RISC-V spec with SystemVerilog arithmetic, using SymbiYosys with the yosys-slang frontend and Bitwuzla ([`formal/muldiv_formal.sv`](formal/muldiv_formal.sv)). Each of the 13 RV64M operations is its own task: reset, one `start`, then a bounded check up to one cycle after `done`, asserting that the result matches the reference, that `done` pulses once, and that `busy` stays high until then.

These are **bounded checks over a restricted operand space, not proofs for every input.** Each operand is built from a few free bits: bit 63, bit 31, a fill bit repeated over bits 62..32, another over bits 30..K, and K free low bits. That includes 0, ±1, small values, INT64_MIN/MAX, INT32_MIN/MAX, all-ones and division by zero. K is 8 for 11 operations and 4 for MULH and MULHSU; at K=8 MULH passed in 2,108 s and MULHSU was stopped unfinished after more than an hour ([muldiv_k8/](results/formal/muldiv_k8/)). `kill` is tied low and only one operation is started per run.

| Check | Result | Log |
| --- | --- | --- |
| All 13 operations against the spec reference | 13 of 13 pass; slowest REMU at 277 s | [summary.txt](results/formal/summary.txt), e.g. [muldiv_div](results/formal/muldiv_div/logfile.txt) |
| Covers (a full-width and a W result, DIV overflow, division by zero) | 4 of 4 reached | [muldiv_cover](results/formal/muldiv_cover/logfile.txt) |
| The 12 M-unit RTL mutants from the simulation campaign, all 13 tasks at K=4 (`scripts/formal_mutants.sh`) | 10 of 12 detected; not detected: `kill_ignored_by_multiplier` and `unit_accepts_start_while_busy`, which need a `kill` or a second `start` that the harness never drives | [mutants.txt](results/formal/mutants.txt) |

### riscv-formal on the pipeline core

`make riscv-formal` runs [riscv-formal](https://github.com/YosysHQ/riscv-formal) (YosysHQ, commit `c992aa6`) on the pipeline core through an RVFI port. The core's retirement trace already carried most RVFI fields; when built with `RISCV_FORMAL` defined, it also reports each retiring instruction's source registers and the forwarded values it actually used ([`rtl/core/core_pipeline.sv`](rtl/core/core_pipeline.sv)). Normal builds do not define it. [`formal/rvfi/env.sv`](formal/rvfi/env.sv) is the environment: each bus accepts a request whenever the solver chooses and returns any data any number of cycles later, bus errors never happen, and the interrupt inputs are 0. SYSTEM and MISC-MEM encodings (CSR, ECALL, EBREAK, MRET, WFI, FENCE, FENCE.I) are assumed away, because riscv-formal has no specification for them; with no CSR writes `mtvec` stays 0, so any trap halts the core. The core and environment are read with yosys-slang, and [`formal/rvfi/wrapper.v`](formal/rvfi/wrapper.v) supplies the free inputs because yosys-slang has no `$anyseq`. Solver: Bitwuzla.

These are **bounded model checks**: each property holds for every instruction sequence and bus timing up to its depth, in cycles from reset. They are not unbounded proofs.

| Check | Depth | Result | Log |
| --- | --- | --- | --- |
| Each of the 49 RV64I instructions riscv-formal models (result, destination, next PC, memory address, byte mask and data, and whether it traps); register-file consistency (`reg`); PC continuity both ways; `causal`; `unique`; every encoding that is neither RV64I nor assumed away traps as illegal (`ill`). M encodings are also assumed away here ([checks.cfg](formal/rvfi/checks.cfg)) | 20 (`reg`, `pc_*` and `causal` from 10) | 55 of 55 pass; slowest `pc_fwd` at 990 s, 2,752 s summed over all checks | [checks.txt](results/riscv-formal/checks.txt) |
| The 13 M instructions, with M encodings allowed in the instruction stream, against riscv-formal's alternative operations ([checks_m.cfg](formal/rvfi/checks_m.cfg)) | 12 | 13 of 13 pass, 177 to 233 s each | [checks_m.txt](results/riscv-formal/checks_m.txt) |
| RTL mutants: the 23 pipeline mutants of the simulation campaign, plus two controls (ADD computes SUB; a wrong alternative-operation constant for MUL) | as above | 16 of 25 detected: both controls and 14 of the 23 pipeline mutants (forwarding, load-use stall, wrong-path flush, branch target, sign extension, ALU and M-operand bugs) | [mutants.txt](results/riscv-formal/mutants.txt), [mutants_m.txt](results/riscv-formal/mutants_m.txt), [failing logs](results/riscv-formal/mutants/) |

**Alternative operations.** With `RISCV_FORMAL_ALTOPS`, riscv-formal replaces each M operation by `(rs1 + rs2)` or `(rs1 - rs2)` XOR a per-operation constant, so a short bound can follow M instructions through the pipeline. [`rtl/core/muldiv_unit.sv`](rtl/core/muldiv_unit.sv) implements those, answering one cycle after `start`, only when that macro is defined. The M checks therefore cover how M instructions move through the core (operands, forwarding, the start/done handshake, writeback), not the arithmetic, which the M-unit checks above cover.

**Why two depths.** With M encodings in the instruction stream, the ADD check at depth 20 was stopped unfinished after 30 minutes, and the MUL check at depth 15 after 40 minutes ([logs](results/riscv-formal/depth-limits/)); without them, every RV64I check at depth 20 finishes, ADD in 24 s. So the main configuration excludes M encodings at depth 20, and the M configuration runs at depth 12.

**What the mutants show.** Most detections come from `reg`, where a forwarding or stall bug makes an instruction read a value that disagrees with the register file, and from `pc_fwd`, for flush and branch-target bugs. The nine missed mutants change behaviour this environment leaves out: seven change traps, interrupts, CSRs or `minstret`, which need CSR instructions, interrupts or a trap handler; `flush_does_not_kill_m` needs a trap while an M instruction is in flight, and here any trap halts the core; and `duplicate_store_issue` writes the same store twice, which changes no register and no retired memory access. The simulation campaign detects all 23.

### Branch prediction, CoreMark and FIR

`make coremark` runs CoreMark ([eembc/coremark](https://github.com/eembc/coremark) at commit `1f483d5`, cloned outside the repository; port in [`sw/coremark/`](sw/coremark/)) and the S3 FIR benchmark (`sw/fir.c`) on the pipeline core in [`tb/core/coremark_tb.sv`](tb/core/coremark_tb.sv), three times: with the full predictor, with `+define+NO_JALR_PRED` (the BHT/BTB for branches and JAL only, the previous front end), and with `+define+NO_BPRED` (no prediction). The testbench memory answers each fetch and data request one cycle after accepting it, so these numbers measure the core and its bus interface, not the SoC's caches or SDRAM. CPI is cycles over retired instructions for the whole run. The misprediction rate is the perf-counter events: mispredictions over control transfers resolved in EX (branches, JAL and JALR). The testbench also counts JALRs and returns (a JALR that reads x1 or x5 and writes x0) and their mispredictions. CoreMark/MHz is iterations × 10⁶ / ticks, where ticks are `mcycle` cycles in CoreMark's timed region. Built with GCC 13.2, `-march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2` ([flags.txt](results/coremark/flags.txt)).

| Program | Front end | CPI | Control transfers | Mispredicted | JALRs mispredicted | Returns mispredicted | CoreMark/MHz | Log |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FIR | no prediction | 6.520 | 4,452 | 2,438 (54.76%) | 4 of 4 | 2 of 2 | | [fir_nobpred.log](results/coremark/fir_nobpred.log) |
| FIR | BHT/BTB, no JALR prediction | 6.101 | 4,452 | 193 (4.34%) | 4 of 4 | 2 of 2 | | [fir_nojalr.log](results/coremark/fir_nojalr.log) |
| FIR | BHT/BTB and return-address stack | 6.101 | 4,452 | 193 (4.34%) | 4 of 4 | 2 of 2 | | [fir_bpred.log](results/coremark/fir_bpred.log) |
| CoreMark | no prediction | 3.102 | 652,013 | 392,845 (60.25%) | 36,749 of 36,749 | 18,343 of 18,343 | 0.894 | [coremark_nobpred.log](results/coremark/coremark_nobpred.log) |
| CoreMark | BHT/BTB, no JALR prediction | 2.856 | 652,013 | 98,904 (15.17%) | 36,749 of 36,749 | 18,343 of 18,343 | 0.971 | [coremark_nojalr.log](results/coremark/coremark_nojalr.log) |
| CoreMark | BHT/BTB and return-address stack | 2.830 | 652,013 | 68,690 (10.54%) | 5,407 of 36,749 | 3,337 of 18,343 | 0.980 | [coremark_bpred.log](results/coremark/coremark_bpred.log) |

Prediction cuts FIR's cycles by 6.4% and CoreMark's by 8.8%, and makes CoreMark 1.096× faster ([summary.txt](results/coremark/summary.txt)). Predicting JALR removes 30.5% of CoreMark's mispredictions (98,904 to 68,690) but only 0.9% of its cycles (1.009×): each avoided redirect saved about 3.1 cycles, and the bus allows one outstanding fetch and one data request, so memory waits dominate. CoreMark is built with `-mcmodel=medany`, so every call is `auipc` + `jalr`, not `jal`. Those calls and tail calls are predicted from the BTB with their last target, and returns from the 8-entry return-address stack. A directed program, `pipe_ras` in [`scripts/rv64_programs.py`](scripts/rv64_programs.py), checks the stack's corner cases against the Python model and Spike like every other program: recursion deeper than 8 entries, x5 as the link register, a callee that returns to ra+4, coroutine swaps (`jalr x1, x5` and `jalr x5, x1`), a JALR that both reads and writes ra, and a return with an odd offset. FIR executes only 4 JALRs, each once, so there is nothing for the predictor to learn. FIR's CPI is high because its inner loop waits on the iterative multiplier. The FIR runs pass only if the program's own checksum matches the Python reference, and all three CoreMark runs produce CoreMark's expected CRCs for the 2K performance run. **The CoreMark numbers are not valid scores under the run rules**: the predicted run's 10 iterations take 10,205,836 cycles, 0.20 s at 50 MHz, and the rules require at least 10 s. CoreMark prints that error, and the runner accepts it only when the CRCs match. CoreMark has not been run on the board. The predictor design and its timing are in [DESIGN.md](DESIGN.md#1-branches-resolve-in-ex-fetch-follows-a-bhtbtb-prediction).

### Hardware FIR filter, MATLAB model and ADC model

[`rtl/peripherals/fir_filter.sv`](rtl/peripherals/fir_filter.sv) is the S3 FIR benchmark's filter in hardware: 16 taps, Q15 coefficients and samples, full-precision products summed in a 37-bit accumulator, rounded half up and saturated exactly as [`sw/fir.c`](sw/fir.c) does. It sits on the bus at 0x1002_0000 when `cpu_soc` is built with `FIR_LANES` (the multiply-accumulates per cycle) above 0. Software writes the coefficients, then each sample to `DATA`, and reads the output back from `DATA`; a read that arrives while the filter is computing is held on the bus until the result is ready, so the driver needs no polling. The register map is in the RTL's header, and the reasons for the design are in [DESIGN.md](DESIGN.md#6-a-fir-filter-peripheral-checked-against-matlab).

**Reference model.** [`matlab/fir_model.m`](matlab/fir_model.m) is a fixed-point model written with Fixed-Point Designer's `fi` (Q15 operands, full-precision sum, `Nearest` rounding, `Saturate`). It checks itself against a plain integer computation, and [`matlab/fir_vectors.m`](matlab/fir_vectors.m) checks that it gives the same outputs and checksum (`0x0fc6e755`, 67 of the 128 outputs saturated) as the Python reference the firmware is built from ([fir_vectors.log](results/fir/fir_vectors.log)). It then writes 13 test cases for the unit bench (1,872 outputs): the firmware's data, random full-range sets, sets that saturate in both directions, the largest positive and negative sums, exact half-LSB rounding ties, single-tap filters and the low-pass filter used below. The cases are committed in [`tests/fir/`](tests/fir/); `make fir` regenerates them with MATLAB and fails if they change.

| Check | Result | Log |
| --- | --- | --- |
| Unit bench ([`tb/unit/fir_tb.sv`](tb/unit/fir_tb.sv)) at 1, 2, 4, 8 and 16 lanes | every one of the 1,872 outputs equals MATLAB's at every lane count; plus register read-back, STATUS while busy, held DATA and coefficient accesses (a coefficient written while busy waits, so the output in flight uses the old one), 16- and 32-bit stores, 13 kinds of error response that change no state, response back-pressure, CLEAR, and the CYCLES and SAMPLES counters: 12,525 checks (12,523 at 16 lanes) | [4 lanes](results/fir/fir_lanes4.log), [1](results/fir/fir_lanes1.log), [2](results/fir/fir_lanes2.log), [8](results/fir/fir_lanes8.log), [16](results/fir/fir_lanes16.log) |
| Mutants ([`scripts/fir_mutants.py`](scripts/fir_mutants.py)) | 18 of 18 detected: no rounding, ties rounded down, no saturation either way, a 32-bit accumulator, unsigned products, lanes misaligned, delay line not shifted, oldest tap dropped, one step short, accumulator not cleared, no hold while busy, coefficient write not held, STATUS held, CLEAR keeping the delay line, byte lanes ignored, writes applied on an error, CYCLES not counted | [fir_mutants.json](results/fir/fir_mutants.json) |
| SoC test ([`tb/core/soc_fir_hw_tb.sv`](tb/core/soc_fir_hw_tb.sv)): [`sw/fir_hw.c`](sw/fir_hw.c) on the pipeline SoC with the filter at 4 lanes | the software filter (`sw/fir.c`'s function, unchanged) and the hardware driver give the same 128 outputs and the reference checksum, and the bench checks each of the 128 `DATA` reads on the bus against MATLAB's output | [test-sim.log](results/test-sim.log) (`SOC_FIR_HW_TEST_PASS`) |
| Cycles for the 128-sample filter, same program, `mcycle` around each call | software 93,495; hardware 2,229 (loading the 16 coefficients, then 7 instructions per sample around the filter's 4 cycles), **41.9x fewer**. The filter itself was busy 512 cycles | same |

The 103,387 cycles quoted for the S3 benchmark above are the whole `fir.c` program on the pipeline; 93,495 is the filter function alone, measured inside `fir_hw.c`.

**ADC model.** [`tb/unit/adc_rnm.sv`](tb/unit/adc_rnm.sv) is a real-number model of a 12-bit sampling ADC: an ideal sample-and-hold on its clock edge, input offset, gain error and Gaussian noise as parameters, quantization to the nearest code with clipping. XSim does not support user-defined nettypes, so the analog input is a `real` variable port. In [`tb/unit/fir_adc_tb.sv`](tb/unit/fir_adc_tb.sv) a real-valued source drives it at 1 MHz (1,024 samples, tones on prime FFT bins so the record is periodic), and each code goes through the filter on its bus port, loaded with a 16-tap Hamming-window low-pass (cutoff 0.1 of the sample rate, designed in MATLAB). [`matlab/adc_fir_check.m`](matlab/adc_fir_check.m) analyses both runs ([adc_fir_check.log](results/fir/adc_fir_check.log)):

| Run | Result |
| --- | --- |
| One tone at -0.92 dBFS, ideal ADC | the bench finds every code within half an LSB of the sampled voltage and the sample-and-hold exact; SNR 73.44 dB against the 12-bit ideal of 73.08 dB for that level (ENOB 12.06); the filter output equals `fir_model` on the same codes, all 1,024 samples |
| Two tones, one in the pass band (0.030 fs) and one in the stop band (0.399 fs), ADC with 100 uV rms noise, 1.5 mV offset and -0.5% gain | filter output equals `fir_model`, all 1,024 samples; gain at the pass-band tone -0.40 dB (-0.40 dB computed from the coefficients); at the stop-band tone -49.56 dB (-49.45 dB computed); the offset reads as 3.06 LSB |

The Signal Processing Toolbox is not installed, so the low-pass is the windowed-sinc design `fir1(15, 0.2)` would make, written out in [`matlab/fir_vectors.m`](matlab/fir_vectors.m). Each sample's write and read take 149.5 ns of the 1 us sample period on the bus.

**Resources and timing, the filter alone at 50 MHz** (`make fir-synth`, [summary.txt](results/fir/synth/summary.txt)). The SoC uses 4 lanes.

| Lanes | Cycles per output | Quartus, MAX 10: logic elements, 9-bit multipliers, setup slack (slow 85 C) | Vivado, Artix-7: LUTs, DSPs, setup slack |
| --- | --- | --- | --- |
| 1 | 16 | 1,309, 2, +2.416 ns | 602, 1, +6.354 ns |
| 4 | 4 | 1,353, 8, +0.877 ns | 592, 5, +0.631 ns |
| 16 | 1 | 1,500, 32, **-0.835 ns** | 487, 17, **-16.968 ns** |

Sixteen lanes, one output per cycle, does not close 50 MHz in either tool: the sum of 16 products in one cycle would need pipelining. Nothing about the filter has run on the board.

### DDR3 through Xilinx's MIG, simulated and implemented

[`rtl/memory/ddr3_bridge.sv`](rtl/memory/ddr3_bridge.sv) puts DDR3 behind the SoC's SDRAM region in place of the DE10-Lite's SDR SDRAM: it takes the same requests the SDR controller takes (single beats with byte masks, 2- and 4-beat read bursts for cache line fills) and drives the native port of a Xilinx MIG 7-series DDR3 controller. The MIG is generated by [`fpga/arty_a7/gen_mig.tcl`](fpga/arty_a7/gen_mig.tcl) from Digilent's settings for the Arty A7-100T (MIT licence, [Digilent/vivado-boards](https://github.com/Digilent/vivado-boards), changed to the native port and an internal system clock; [`mig_ddr3.prj`](fpga/arty_a7/mig_ddr3.prj)): an MT41K128M16 at 325 MHz, 4:1 PHY, so the MIG's user clock is 81.25 MHz. The SoC stays at 50 MHz and the bridge crosses between the clocks with two async FIFOs ([`async_fifo.sv`](rtl/memory/async_fifo.sv), the network engine's formally checked design). The reasons are in [DESIGN.md](DESIGN.md#7-ddr3-through-xilinxs-mig-as-a-second-memory-back-end). **Nothing here has run on hardware**: everything below is simulation (XSim, the MIG's simulation build with its fast calibration, Micron's DDR3 model from the MIG example design) or implementation.

| Check | Result | Log |
| --- | --- | --- |
| Bridge bench ([`tb/ddr3/ddr3_bridge_tb.sv`](tb/ddr3/ddr3_bridge_tb.sv)) on DDR3: 3,000 random requests after seeding the first 4 KiB | every read checked against a byte-level reference: single beats with random byte masks (unrequested lanes must read zero), 2- and 4-beat bursts, writes with random masks, 391 requests that must answer with one error beat, random response back-pressure on single beats, a bus reset with a line read in flight; 25,656 checks pass. The MIG calibrates against the model; the model reports no errors (only the warnings expected from shortened power-up and write leveling) | [bridge_ddr3.log](results/ddr3/bridge_ddr3.log) |
| The same bench on the SDR path (`sdram_ctrl` + `sdram_model`) | 26,166 checks pass | [bridge_sdr.log](results/ddr3/bridge_sdr.log) |
| Read latency, request accepted to first beat, 64 dependent single reads, 50 MHz SoC cycles | DDR3 18.2 mean (18 to 22); SDR 10.0 (10 to 11). The DDR3 path adds two clock crossings and the MIG's command and read pipelines | same |
| Back-to-back 32-byte line reads, 128 of them | DDR3 1.45 bytes per SoC cycle (72.3 MB/s at 50 MHz); SDR 1.39 (69.4 MB/s). One request in flight on the SoC bus limits both | same |
| S6 programs on DDR3 ([`tb/ddr3/soc_ddr3_tb.sv`](tb/ddr3/soc_ddr3_tb.sv)): `s6_icache`, `s6_dcache`, `s6_fetch_end`, `s6_random_7`, `s5_sdram_cached`, `s5_random_5_cached`, `s6_random_7_uncached`, pipeline core with both caches | all 7 pass the S6 checker's cache-aware model (every retirement, every bus access, every line fill and uncached access, the final on-chip RAM and the final DDR3 contents), and each has the same retirements as the SDR run of the same program | [soc_ddr3_check.json](results/ddr3/soc/soc_ddr3_check.json), [run.log](results/ddr3/soc/run.log) |

Two things differ from the SDR runs. Micron's model returns X for memory never written, where the SDR model returns zeros; three of the programs read 13 such responses in total, speculatively past the end of code they copied to SDRAM, and the checker counts them and reads them as zero (the identical retirements show they were discarded). And the MIG's write calibration leaves training patterns at address 0, so the bench empties the model's store when the CPU starts, before the program writes anything. The SoC runs' cycle counts are not comparable with the S6 bench's: that bench starts the CPU during the SDR power-up wait, this one after calibration. Running these programs is how a bug was found: single-beat reads returned all eight bytes instead of zeros in the unrequested lanes, which the uncached run's checker caught; the bridge bench now checks it.

**Implementation for the Arty A7-100T** ([`fpga/arty_a7/arty_ddr3_top.sv`](fpga/arty_a7/arty_ddr3_top.sv), [`build_arty.tcl`](fpga/arty_a7/build_arty.tcl), pins from Digilent's master XDC in [`arty_ddr3.xdc`](fpga/arty_a7/arty_ddr3.xdc)): the pipeline SoC with caches, the bridge, the MIG and one MMCM for 50, 100 and 200 MHz, with the S5 SDRAM test firmware in the boot ROM. Vivado 2025.2 places, routes and writes a bitstream ([result.txt](results/vivado/arty_ddr3/result.txt)): 16,915 slice LUTs, 12,737 registers, 24 block RAM tiles; worst setup slack +0.553 ns and hold +0.029 ns over all clocks ([timing](results/vivado/arty_ddr3/timing_summary.txt)); 0 DRC errors ([drc.txt](results/vivado/arty_ddr3/drc.txt)). The clock crossings are bounded to the user clock's 12.308 ns, Gray-pointer skew included ([bus_skew.txt](results/vivado/arty_ddr3/bus_skew.txt)). `report_cdc` lists 213 CDC-1 and 168 CDC-13 critical items, all reads of the two FIFOs' LUT memories from the other clock (the FIFO protocol guarantees the word is stable before its pointer is seen; the network engine's identical FIFO has a formal proof), and one CDC-2 warning on the existing UART's receive synchronizer, which lacks the `ASYNC_REG` attribute ([cdc.txt](results/vivado/arty_ddr3/cdc.txt)). The bitstream has not been loaded on a board.

### Second simulator: Questa

`make questa` ([`scripts/run_questa.ps1`](scripts/run_questa.ps1)) runs the directed and self-checking benches in Questa Intel Starter FPGA Edition 2024.3, with the same sources, parameters, plusargs and pass markers as the XSim scripts. The UVM bench does not run there: the free licence has no SystemVerilog verification feature, so Questa refuses `randomize()` and covergroups (error vsim-1), which `tb/uvm` uses.

| Check | Result | Log |
| --- | --- | --- |
| Unit benches: RAM, M unit (2 seeds), cache (2 sizes, 4 runs), SDRAM controller (50 and 100 MHz, 4 runs) and tester, accelerator (4 configurations, 6 runs), FIR filter at 1, 2, 4, 8 and 16 lanes, ADC-model bench (2 tests) | 25 of 25 pass; the accelerator transcripts also pass the Python replay | [summary.txt](results/questa/summary.txt), [units/](results/questa/units/) |
| Both cores' full trace matrices (the same groups as `make test-sim`) | 132 multicycle traces (38,972 retirements) and 248 pipeline traces (92,699) pass the reference-model checker | [check_all_multicycle.txt](results/questa/check_all_multicycle.txt), [check_all_pipeline.txt](results/questa/check_all_pipeline.txt) |
| The same traces against XSim's, file for file ([`scripts/compare_sim_traces.pl`](scripts/compare_sim_traces.pl), Perl) | identical: 758 of 758 files (379 traces, with 380,793 trace lines, and their final memory dumps) | [trace_compare.json](results/questa/trace_compare.json) |
| Integration benches: the 18 runs of `run_integration.ps1` (SoC firmware on both cores, fault benches, board top with all six demos) | 18 of 18 pass | [integration/](results/questa/integration/) |

Comparing the traces found a race in the core benches, now fixed: they released reset with a blocking assignment on a falling edge that the bus model's process also reads it on, so the two simulators ordered the two processes differently and XSim ran one cycle ahead of Questa. Every trace still passed the checker in both, but two traces with a reset at a fixed cycle retired one more instruction before it in XSim. The benches now drive reset with nonblocking assignments; XSim's counts went from 38,973 and 92,700 to the 38,972 and 92,699 above, and the two simulators then agree on every trace.

### Not yet backed by a log

The board runs (S3 to S8) were read from the HEX displays and LEDs by hand, so there is no log for them. They are left out here until they are recorded, for example as photos or a System Console readout saved under `results/board/`. This covers the S6 cache cycle counts, the S7 accelerator per-case cycles, the S8 checksum, the 16x16 product and 64-case cycle counts, and the board-to-simulation agreement.

## Problems found while building it

1. **SDRAM read one word late (S5).** The first two board images read every SDRAM word one word late, although simulation passed. The SDRAM model drove data one clock after the datasheet's edge, and the controller had been tuned to the model. A gate-level simulation ruled out synthesis; re-reading the datasheet's CAS-latency definition found the cause. The model and controller were fixed.
2. **Interrupt lowered during writeback (S4).** Random interrupt tests showed that if an interrupt source dropped in the same cycle the interrupted instruction reached writeback, the front end could still deliver that instruction. Trap entry now flushes the front end.
3. **Cache address alias (S6).** An address just outside the cached SDRAM region could hit in the cache because the tag stored only the offset inside the region. The cache unit bench caught it with random requests.
4. **Registers removed by Quartus (S7).** Quartus decided some accelerator control bits were never read, because they were read only inside a function through module scope, and removed them. XSIM simulated them correctly. The synthesis log showed it, and the read path was rewritten as plain logic.
5. **Reset race in the core benches.** Running the trace matrices in Questa as well as XSim showed two traces that retired one instruction fewer in Questa. The benches released reset with a blocking assignment on the same edge another process read it on, so the result depended on the simulator's process order. Reset is now a nonblocking assignment and the traces are identical in both simulators. See [Second simulator: Questa](#second-simulator-questa).
6. **Tool and file problems.** XSIM's optimized elaboration returned zero load data when the pipeline had two `load_store` instances (found by the UVM bench). Scripted edits on Windows converted files to CRLF line endings and broke the WSL tools, so `.gitattributes` keeps every file byte-exact.

Design decisions and the reasoning behind them are in [DESIGN.md](DESIGN.md).

## Limitations

- No UART link on the board (no USB-serial adapter); the UART is verified in simulation.
- Machine mode only: no compressed or floating-point instructions, S/U modes, MMU, PMP, A extension or debug.
- 50 MHz only; 100 MHz was not attempted.
- SDRAM board trace delays are assumed in timing analysis; the board runs are the physical evidence.
- Every misprediction flushes the two younger instructions. The return-address stack has 8 entries and wraps on deeper recursion, losing the oldest return addresses; MRET and FENCE.I always redirect.
- Verification is extensive but finite. The formal checks are bounded: the M unit over a restricted operand space, and the pipeline (riscv-formal) to 20 cycles from reset, 12 for M instructions, with no CSR instructions, interrupts or trap handlers. Passing riscv-arch-test is not a certification.

## Layout

| Path | Contents |
| --- | --- |
| `rtl/` | Cores, M unit, CSRs, bus, memories, SDRAM, caches, peripherals, accelerator |
| `fpga/de10_lite/` | Board top level, pins, timing constraints, PLL, Quartus Tcl |
| `fpga/arty_a7/` | Arty A7-100T top with DDR3, MIG settings and generation, pins, Vivado build |
| `sw/` | Startup code, linker scripts, firmware |
| `tb/` | Unit, CPU/SoC/board and UVM testbenches |
| `model/`, `tests/` | Python reference models and their pytest tests; `tests/fir/` holds the FIR test vectors MATLAB writes |
| `matlab/` | Fixed-point model of the FIR filter, its vector generator, and the analysis of the ADC-model bench |
| `scripts/` | Firmware build, simulation, checking, regression, synthesis, board build, programming and result collection |
| `sw/coremark/` | CoreMark port: mcycle timing, console output, start code and linker script |
| `formal/` | SymbiYosys harness, `.sby` file and task list for `make formal`; `formal/rvfi/` holds the riscv-formal configurations and environment |
| `config/` | Address map and regression run lists |
| `sim/cpu_sim/` | XSIM smoke test used by the tool qualification |
| `results/` | Committed logs and reports behind the numbers in this README |
| `docs/` | Block diagram |

Generated output goes to `build/`, which Git ignores.
