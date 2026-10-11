`timescale 1ns/1ps
import uvm_pkg::*;
`include "uvm_macros.svh"

class probe_item extends uvm_sequence_item;
  `uvm_object_utils(probe_item)
  rand bit [7:0] lane;
  rand int unsigned delay;
  rand bit [4:0] reg_index;
  rand bit [2:0] kind;
  constraint c_lane { lane inside {[0:3]}; }
  constraint c_delay { delay dist {0 := 4, [1:3] := 3, [4:9] := 1}; }
  constraint c_kind { kind != 7; }
  function new(string name = "probe_item"); super.new(name); endfunction
endclass

class probe_component extends uvm_component;
  `uvm_component_utils(probe_component)
  rand bit [7:0] value;
  constraint c_value { value inside {[0:3]}; }
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class random_probe_test extends uvm_test;
  `uvm_component_utils(random_probe_test)
  probe_component comp;
  rand bit [7:0] self_value;
  constraint c_self { self_value inside {[0:3]}; }
  function new(string name = "random_probe_test", uvm_component parent = null); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase); comp = new("comp", this); endfunction
  task run_phase(uvm_phase phase);
    probe_item item = probe_item::type_id::create("item");
    int lane_hist[4], kind_hist[8], delay_zero = 0, delay_mid = 0, delay_high = 0, reg_distinct = 0;
    int comp_hist[4], std_hist[16], inline_hist[4], self_hist[4];
    bit [31:0] reg_seen = 0;
    bit [3:0] local_value;
    phase.raise_objection(this);
    repeat (1000) begin
      if (!item.randomize()) `uvm_fatal("PROBE", "item.randomize failed")
      if (item.lane > 3 || item.kind == 7 || item.delay > 9) `uvm_fatal("PROBE", "constraint violated")
      lane_hist[item.lane]++; kind_hist[item.kind]++;
      if (item.delay == 0) delay_zero++; else if (item.delay <= 3) delay_mid++; else delay_high++;
      reg_seen[item.reg_index] = 1;
      if (!item.randomize() with { lane == 2; }) `uvm_fatal("PROBE", "inline randomize failed")
      if (item.lane != 2) `uvm_fatal("PROBE", "inline constraint violated")
      inline_hist[item.lane]++;
      if (!std::randomize(local_value)) `uvm_fatal("PROBE", "std::randomize failed")
      std_hist[local_value]++;
      if (!comp.randomize()) `uvm_fatal("PROBE", "component randomize failed")
      comp_hist[comp.value]++;
      if (!this.randomize()) `uvm_fatal("PROBE", "test self-randomize failed")
      self_hist[self_value]++;
    end
    foreach (reg_seen[i]) reg_distinct += reg_seen[i];
    $display("PROBE item.lane histogram: %0d %0d %0d %0d", lane_hist[0], lane_hist[1], lane_hist[2], lane_hist[3]);
    $display("PROBE item.kind histogram: %0d %0d %0d %0d %0d %0d %0d %0d", kind_hist[0], kind_hist[1], kind_hist[2],
             kind_hist[3], kind_hist[4], kind_hist[5], kind_hist[6], kind_hist[7]);
    $display("PROBE item.delay dist: zero=%0d 1..3=%0d 4..9=%0d (weights 4:9:6 by value count)", delay_zero, delay_mid, delay_high);
    $display("PROBE item.reg_index distinct values: %0d of 32", reg_distinct);
    $display("PROBE std::randomize 4-bit: first eight bins %0d %0d %0d %0d %0d %0d %0d %0d", std_hist[0], std_hist[1],
             std_hist[2], std_hist[3], std_hist[4], std_hist[5], std_hist[6], std_hist[7]);
    $display("PROBE component.randomize histogram (child component): %0d %0d %0d %0d", comp_hist[0], comp_hist[1], comp_hist[2], comp_hist[3]);
    $display("PROBE test this.randomize histogram (S0 smoke form): %0d %0d %0d %0d", self_hist[0], self_hist[1], self_hist[2], self_hist[3]);
    foreach (lane_hist[i]) if (lane_hist[i] < 150) `uvm_error("PROBE", $sformatf("item.lane bin %0d starved", i))
    for (int i = 0; i < 7; i++) if (kind_hist[i] < 70) `uvm_error("PROBE", $sformatf("item.kind bin %0d starved", i))
    if (reg_distinct != 32 || delay_zero < 100 || delay_mid < 300 || delay_high < 150)
      `uvm_error("PROBE", "item variation too narrow")
    if (comp_hist[0] == 1000) `uvm_warning("PROBE", "uvm_component randomize returned only zero (S0 limitation reproduced)")
    `uvm_info("PROBE", "RANDOM_PROBE_DONE", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

module random_probe_tb;
  initial run_test("random_probe_test");
endmodule
