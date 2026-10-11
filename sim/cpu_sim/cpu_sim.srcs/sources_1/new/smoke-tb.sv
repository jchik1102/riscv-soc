`timescale 1ns / 1ps

import uvm_pkg::*;
`include "uvm_macros.svh"

class feature_test extends uvm_test;
    `uvm_component_utils(feature_test)

    rand bit [7:0] value;
    constraint small_values { value inside {[0:3]}; }

    covergroup values_cg;
        option.per_instance = 1;
        cp_value: coverpoint value {
            bins each_value[] = {[0:3]};
        }
    endgroup

    function new(string name = "feature_test",
                 uvm_component parent = null);
        super.new(name, parent);
        values_cg = new();
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        repeat (256) begin
            if (!randomize())
                `uvm_fatal("RANDOM", "Randomization failed")

            if (value > 3)
                `uvm_fatal("CONSTRAINT", "Constraint was violated")

            values_cg.sample();
            #1;
        end
for (int i = 0; i < 4; i++) begin
    value = i;
    values_cg.sample();
    #1;
end

$display("Type coverage: %0.2f%%",
         values_cg.get_coverage());
$display("Instance coverage: %0.2f%%",
         values_cg.get_inst_coverage());
        if (values_cg.get_inst_coverage() < 100.0)
            `uvm_fatal("COVERAGE", "Not all four values were covered")

        `uvm_info("CHECK",
                  "PASS: UVM, randomization, and coverage work",
                  UVM_LOW)

        phase.drop_objection(this);
    endtask
endclass

module smoke_tb;
    initial run_test("feature_test");
endmodule
