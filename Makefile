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

.PHONY: help models test test-sim test-uvm fpga fpga-synth vivado program results act riscvdv formal riscv-formal riscv-formal-mutants coremark fir fir-synth ddr3 arty questa results-dir

help:
	@echo "make models     Python model/checker tests (WSL only, seconds)"
	@echo "make test       test-sim + test-uvm (XSim on Windows, long)"
	@echo "make test-sim   scripts/regress.ps1, ends REGRESSION_PASS"
	@echo "make test-uvm   scripts/regress_uvm.ps1, ends UVM_REGRESSION_PASS"
	@echo "make fpga       scripts/build_board.ps1 -Stage s8 -Demo s8 -Power"
	@echo "make fpga-synth scripts/synthesize.ps1 -Stage s8 -Pipeline 1 -AccelN 4"
	@echo "make vivado     Vivado implementation of the fpga-synth configuration for an Artix-7 at 50 MHz"
	@echo "make program    scripts/program_board.ps1 -Stage s8 (board connected)"
	@echo "make results    copy logs and reports that back the README into results/"
	@echo "make act        riscv-arch-test (ACT4) RV64I+RV64M on the pipeline core and Spike"
	@echo "make riscvdv    riscv-dv random programs (INSTR_CNT=300), RTL and Spike vs the model"
	@echo "make coremark   CoreMark (ITERATIONS=10) and FIR on the pipeline core: no prediction, no JALR prediction, full"
	@echo "make formal     SymbiYosys checks in formal/ (results/formal/summary.txt)"
	@echo "make riscv-formal         riscv-formal checks of the pipeline core (results/riscv-formal/)"
	@echo "make riscv-formal-mutants the same checks on RTL mutants; each must fail one"
	@echo "make fir        hardware FIR filter: MATLAB vectors, unit bench at 5 lane counts, ADC-model bench, mutants"
	@echo "make fir-synth  the FIR filter alone in Quartus (MAX 10) and Vivado (Artix-7) at 50 MHz, LANES 1, 4, 16"
	@echo "make ddr3       DDR3 back end in simulation: bridge bench on DDR3 (MIG + Micron model) and SDR, then S6 programs on DDR3"
	@echo "make arty       Vivado implementation of the Arty A7-100T top with DDR3 (bitstream, not run on a board)"
	@echo "make questa     the directed benches in Questa Starter: units, both cores' trace matrices (model-checked, compared with XSim), integration"

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

# Vivado 2025.2 out-of-context synthesis, placement and routing of the
# fpga-synth configuration (fpga/de10_lite/synthesis_top.sv, pipeline core and
# 4x4 accelerator) for an Artix-7 (xc7a100tcsg324-1) at 50 MHz; reports
# copied to results/vivado/.
vivado: | results-dir
	$(PS) scripts/run-vivado.ps1 $(LOG)
	mkdir -p $(RESULTS)/vivado
	cp build/vivado/synthesis_top/{result.txt,utilization.txt,utilization_hierarchy.txt,timing_summary.txt,worst_setup_path.txt} $(RESULTS)/vivado/
	@$(call require,^VIVADO_PASS,$(RESULTS)/vivado/result.txt)

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

# riscv-formal (YosysHQ) on the pipeline core through its RVFI port
# (formal/rvfi/). Needs riscv-formal in RVF (default ~/hwtools/riscv-formal)
# and OSS CAD Suite with yosys-slang on PATH.
riscv-formal: | results-dir
	bash scripts/run_riscv_formal.sh 2>&1 | tee $(RESULTS)/riscv-formal.log

riscv-formal-mutants: | results-dir
	bash scripts/riscv_formal_mutants.sh 2>&1 | tee $(RESULTS)/riscv-formal-mutants.log

# CoreMark and the S3 FIR benchmark on the pipeline core in
# tb/core/coremark_tb.sv, with and without branch prediction (+define+NO_BPRED)
# and with the BTB but no JALR prediction (+define+NO_JALR_PRED).
# Results in results/coremark/.
ITERATIONS ?= 10
coremark: | results-dir
	mkdir -p $(RESULTS)/coremark
	bash scripts/coremark_build.sh $(ITERATIONS) 2>&1 | tee $(RESULTS)/coremark/build.log
	$(VENV)/bin/python -m scripts.programs > /dev/null
	for p in fir coremark; do for v in nobpred nojalr bpred; do 	  $(PS) scripts/run_coremark.ps1 -Program $$p -Variant $$v 2>&1 | tee $(RESULTS)/coremark/run_$${p}_$$v.log; 	  grep -q "^COREMARK_RUN_PASS program=$$p variant=$$v" $(RESULTS)/coremark/run_$${p}_$$v.log || { echo "FAIL: $$p $$v"; exit 1; }; 	done; done
	$(VENV)/bin/python -m scripts.coremark_report

# Hardware FIR filter (rtl/peripherals/fir_filter.sv): MATLAB regenerates the
# expected outputs and they must equal tests/fir/; the unit bench at LANES 1,
# 2, 4, 8 and 16; the ADC-model bench with MATLAB's analysis; the mutants.
# The SoC test (tb/core/soc_fir_hw_tb.sv) runs in make test-sim.
FIR_LOGS = fir_lanes1.log fir_lanes2.log fir_lanes4.log fir_lanes8.log fir_lanes16.log fir_adc_test0.log fir_adc_test1.log   fir_adc_test0.csv fir_adc_test1.csv adc_fir_check.log
fir: | results-dir
	$(PS) scripts/run_fir.ps1 $(LOG)
	mkdir -p $(RESULTS)/fir
	cd build/xsim_fir && cp $(FIR_LOGS) ../../$(RESULTS)/fir/
	cp build/fir/fir_vectors.log build/fir_mutants.json $(RESULTS)/fir/
	@$(call require,^FIR_MUTANTS_PASS,$(RESULTS)/$@.log)
	@$(call require,^FIR_ADC_MATLAB_PASS,$(RESULTS)/$@.log)

fir-synth: | results-dir
	$(PS) scripts/run_fir_synth.ps1 $(LOG)
	mkdir -p $(RESULTS)/fir/synth
	cp build/fir_synth/* $(RESULTS)/fir/synth/
	@$(call require,^FIR_SYNTH_DONE,$(RESULTS)/$@.log)

# DDR3 back end (rtl/memory/ddr3_bridge.sv), simulation only: the bridge bench
# on DDR3 (MIG simulation build + Micron model) and on the SDR path, then S6
# SoC programs on DDR3 checked against the cache model and the SDR runs
# (needs build/xsim_soc_s6 from make test-sim). The MIG is generated into
# build/mig/ by fpga/arty_a7/gen_mig.tcl when missing.
ddr3: | results-dir
	$(PS) scripts/run_ddr3.ps1 $(LOG)
	$(PS) scripts/run_soc_ddr3.ps1 2>&1 | tee -a $(RESULTS)/$@.log
	mkdir -p $(RESULTS)/ddr3/soc
	cp build/xsim_ddr3/bridge_mem1.log $(RESULTS)/ddr3/bridge_ddr3.log
	cp build/xsim_ddr3/bridge_mem0.log $(RESULTS)/ddr3/bridge_sdr.log
	cd build/xsim_soc_ddr3 && cp soc_ddr3_check.json $$(ls *.log | grep -v -e backup -e '^compile_' -e '^elab_' -e '^x') ../../$(RESULTS)/ddr3/soc/
	@$(call require,^DDR3_SOC_PASS,$(RESULTS)/$@.log)

# Arty A7-100T board top with the SoC, caches and DDR3: Vivado synthesis,
# placement, routing, reports and bitstream. Implemented only, never run.
arty: | results-dir
	$(VENV)/bin/python -m scripts.programs > /dev/null
	mkdir -p build/vivado/arty_ddr3 $(RESULTS)/vivado/arty_ddr3
	cd build/vivado/arty_ddr3 && "/mnt/c/AMDDesignTools/2025.2/Vivado/bin/vivado.bat" -mode batch -nojournal -log vivado.log 	  -source C:/projects/riscv-soc/fpga/arty_a7/build_arty.tcl -tclargs C:/projects/riscv-soc/build/firmware/s5_board_words.hex 2>&1 | tee ../../../$(RESULTS)/$@.log
	cd build/vivado/arty_ddr3 && cp result.txt utilization.txt utilization_hierarchy.txt timing_summary.txt worst_setup_path.txt clock_interaction.txt cdc.txt bus_skew.txt drc.txt ../../../$(RESULTS)/vivado/arty_ddr3/
	@$(call require,^ARTY_PASS,$(RESULTS)/vivado/arty_ddr3/result.txt)

# Questa Intel Starter FPGA Edition (Windows): the unit benches, both cores'
# trace matrices (checked by the reference model, then compared file for file
# with XSim's traces from make test-sim) and the integration benches. The UVM
# bench needs randomize() and covergroups, which the Starter licence refuses.
# Logs in results/questa/.
questa: | results-dir
	$(PS) scripts/run_questa.ps1 $(LOG)
	$(VENV)/bin/python scripts/compare_sim_traces.py 2>&1 | tee -a $(RESULTS)/$@.log
	mkdir -p $(RESULTS)/questa/units $(RESULTS)/questa/integration
	cp build/questa/summary.txt build/questa/trace_compare.json $(RESULTS)/questa/
	cp build/questa/core/check_all.txt $(RESULTS)/questa/check_all_multicycle.txt
	cp build/questa/pipe/check_all.txt $(RESULTS)/questa/check_all_pipeline.txt
	cp build/questa/units/*.log $(RESULTS)/questa/units/
	cp build/questa/integration/*_p?.log $(RESULTS)/questa/integration/
	@$(call require,^QUESTA_DONE,$(RESULTS)/$@.log)
	@$(call require,^TRACES_IDENTICAL,$(RESULTS)/$@.log)
