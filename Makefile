# Thin wrapper around the existing flows. Run from WSL in the repository root:
#   make test     full simulation regression (scripts/regress.ps1, then regress_uvm.ps1)
#   make fpga     Quartus S8 board build with power estimate (no programming)
#   make formal   SymbiYosys checks listed in formal/tasks.txt
# XSim and Quartus run on Windows; the PowerShell scripts call back into WSL for
# GCC, Python and Spike. Console output is saved under results/.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

PWSH_FALLBACK := /mnt/c/Users/jonat/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe
PWSH ?= $(or $(shell command -v pwsh.exe 2>/dev/null),$(PWSH_FALLBACK))
PS := "$(PWSH)" -NoProfile -ExecutionPolicy Bypass -File
VENV ?= /home/jonat/.venvs/riscv-soc
RESULTS := results
# pwsh.exe launched from WSL reports exit code 0 even when a script fails, so
# every PowerShell step is judged by the pass marker it prints, like the
# XSim logs are.
require = grep -qE '$(1)' $(2) || { echo "FAIL: '$(1)' not found in $(2)"; exit 1; }
LOG = 2>&1 | tee $(RESULTS)/$@.log

.PHONY: help models test test-sim test-uvm fpga fpga-synth program results act riscvdv formal coremark results-dir

help:
	@echo "make models     Python model/checker tests (WSL only, seconds)"
	@echo "make test       test-sim + test-uvm (XSim on Windows, long)"
	@echo "make test-sim   scripts/regress.ps1, ends REGRESSION_PASS"
	@echo "make test-uvm   scripts/regress_uvm.ps1, ends UVM_REGRESSION_PASS"
	@echo "make fpga       scripts/build_board.ps1 -Stage s8 -Demo s8 -Power"
	@echo "make fpga-synth scripts/synthesize.ps1 -Stage s8 -Pipeline 1 -AccelN 4"
	@echo "make program    scripts/program_board.ps1 -Stage s8 (board connected)"
	@echo "make results    copy logs and reports that back the README into results/"
	@echo "make act        riscv-arch-test (ACT4) RV64I+RV64M on the pipeline core and Spike"
	@echo "make riscvdv    riscv-dv random programs (INSTR_CNT=300), RTL and Spike vs the model"
	@echo "make coremark   CoreMark (ITERATIONS=10) and FIR on the pipeline core, with and without prediction"
	@echo "make formal     SymbiYosys checks in formal/ (results/formal/summary.txt)"

# Not "$(RESULTS):": that is the same target as "results:" below, whose
# recipe would then run before every target.
results-dir:
	@mkdir -p $(RESULTS)

models: | results-dir
	$(VENV)/bin/python -m pytest -q $(LOG)

test: test-sim test-uvm
	$(VENV)/bin/python scripts/collect_results.py

test-sim: | results-dir
	$(PS) scripts/regress.ps1 $(LOG)
	@$(call require,^REGRESSION_PASS,$(RESULTS)/$@.log)

test-uvm: | results-dir
	$(PS) scripts/regress_uvm.ps1 $(LOG)
	@$(call require,^UVM_REGRESSION_PASS,$(RESULTS)/$@.log)

fpga: | results-dir
	$(PS) scripts/build_board.ps1 -Stage s8 -Demo s8 -Power $(LOG)
	@$(call require,^POWER_ESTIMATE_DONE,$(RESULTS)/$@.log)
	$(VENV)/bin/python scripts/collect_results.py

fpga-synth: | results-dir
	$(PS) scripts/synthesize.ps1 -Stage s8 -Pipeline 1 -AccelN 4 $(LOG)
	@$(call require,^SYNTHESIS_PASS,$(RESULTS)/$@.log)

program:
	$(PS) scripts/program_board.ps1 -Stage s8 $(LOG)
	@$(call require,^PROGRAMMED,$(RESULTS)/$@.log)

results:
	$(VENV)/bin/python scripts/collect_results.py

# riscv-arch-test (ACT4): build self-checking ELFs (expected values from Sail),
# run them on the pipeline core (pipe_tb with a 256 KiB testbench memory) and
# cross-check the same ELFs on Spike.
act: | results-dir
	mkdir -p $(RESULTS)/act4
	bash scripts/act_build.sh 2>&1 | tee $(RESULTS)/act4/build.log
	$(VENV)/bin/python scripts/act_check.py --spike 2>&1 | tee $(RESULTS)/act4/spike.log
	$(PS) scripts/run_act.ps1 2>&1 | tee $(RESULTS)/act4/rtl.log
	@$(call require,^ACT_SPIKE_TOTAL pass=([0-9]+) of \1,$(RESULTS)/act4/spike.log)
	@$(call require,^ACT_RTL_TOTAL pass=([0-9]+) of \1,$(RESULTS)/act4/rtl.log)

# riscv-dv: pyflow-generated random programs at INSTR_CNT instructions, Spike and
# the RTL each checked against the Python model.
INSTR_CNT ?= 300
DV_TAG ?= n$(INSTR_CNT)
riscvdv: | results-dir
	mkdir -p $(RESULTS)/riscv-dv/$(DV_TAG)
	bash scripts/riscvdv_gen.sh $(DV_TAG) $(INSTR_CNT) 2>&1 | tee $(RESULTS)/riscv-dv/$(DV_TAG)/gen.log
	$(PS) scripts/run_riscvdv.ps1 -Tag $(DV_TAG) 2>&1 | tee $(RESULTS)/riscv-dv/$(DV_TAG)/rtl.log
	cp build/riscv-dv/$(DV_TAG)/results.json build/riscv-dv/$(DV_TAG)/spike.json build/riscv-dv/$(DV_TAG)/testlist.yaml $(RESULTS)/riscv-dv/$(DV_TAG)/
	@$(call require,^RISCVDV_TOTAL pass=([0-9]+) of \1 programs,$(RESULTS)/riscv-dv/$(DV_TAG)/rtl.log)

# SymbiYosys proofs, bounded checks and covers listed in formal/tasks.txt.
# Needs OSS CAD Suite on PATH (yosys with the slang plugin, sby, solvers).
formal: | results-dir
	bash scripts/run-formal.sh

# CoreMark and the S3 FIR benchmark on the pipeline core in
# tb/core/coremark_tb.sv, with and without branch prediction (+define+NO_BPRED).
# Results in results/coremark/.
ITERATIONS ?= 10
coremark: | results-dir
	mkdir -p $(RESULTS)/coremark
	bash scripts/coremark_build.sh $(ITERATIONS) 2>&1 | tee $(RESULTS)/coremark/build.log
	$(VENV)/bin/python -m scripts.programs > /dev/null
	for p in fir coremark; do for v in nobpred bpred; do 	  $(PS) scripts/run_coremark.ps1 -Program $$p -Variant $$v 2>&1 | tee $(RESULTS)/coremark/run_$${p}_$$v.log; 	  grep -q "^COREMARK_RUN_PASS program=$$p variant=$$v" $(RESULTS)/coremark/run_$${p}_$$v.log || { echo "FAIL: $$p $$v"; exit 1; }; 	done; done
	$(VENV)/bin/python -m scripts.coremark_report
