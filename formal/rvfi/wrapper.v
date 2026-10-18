// rvfi_wrapper for riscv-formal: the free inputs of the environment
// (bus handshakes and data), declared with riscv-formal's rvformal_rand_reg
// so Yosys's frontend makes them free every cycle, and rvfi_core_env
// (env.sv, read with yosys-slang) holding the core.
module rvfi_wrapper (
	input clock,
	input reset,
	`RVFI_OUTPUTS
);
	(* keep *) `rvformal_rand_reg ireq_free;
	(* keep *) `rvformal_rand_reg irsp_free;
	(* keep *) `rvformal_rand_reg dreq_free;
	(* keep *) `rvformal_rand_reg drsp_free;
	(* keep *) `rvformal_rand_reg [63:0] irdata;
	(* keep *) `rvformal_rand_reg [63:0] drdata;

	rvfi_core_env env (
		.clock(clock), .reset(reset),
		.ireq_free(ireq_free), .irsp_free(irsp_free), .dreq_free(dreq_free), .drsp_free(drsp_free),
		.irdata(irdata), .drdata(drdata),
		`RVFI_CONN
	);
endmodule
