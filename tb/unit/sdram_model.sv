`timescale 1ns/1ps
module sdram_model #(
  parameter real T_POWERUP = 100000.0,
  parameter int INIT_REFRESHES = 8,
  parameter real T_RC = 60.0, T_RAS = 42.0, T_RAS_MAX = 100000.0, T_RP = 18.0, T_RCD = 18.0,
  parameter real T_RRD = 14.0, T_DPL = 14.0, T_DAL = 30.0, T_MRD = 14.0,
  parameter real T_AC = 6.0, T_OH = 2.5, T_HZ = 6.0,
  parameter real T_SETUP = 1.8, T_HOLD = 0.8,
  parameter real T_CK_CL2 = 10.0, T_CK_CL3 = 7.0,
  parameter real T_REFI_MAX = 7812.5
) (
  input logic clk, cke, cs_n, ras_n, cas_n, we_n,
  input logic [1:0] ba,
  input logic [12:0] a,
  input logic [1:0] dqm,
  inout wire [15:0] dq
);
  int errors = 0;
  int n_active = 0, n_read = 0, n_write = 0, n_refresh = 0, n_precharge = 0, n_mode = 0, n_auto_precharge = 0;
  int n_bank_change = 0, n_row_change = 0, n_row_same = 0;
  realtime max_refresh_gap = 0;
  bit initialized = 0, refresh_late = 0;

  logic [7:0] mem [bit [25:0]];
  function automatic bit [25:0] key(input logic [1:0] b, input logic [12:0] r, input logic [9:0] c, input bit hi);
    return {b, r, c, hi};
  endfunction

  realtime t_power, last_edge, last_change;
  int unsigned edge_no = 0;
  int init_step;
  int init_refreshes;
  int burst_length, cas_latency;
  bit active [4];
  bit auto_pending [4];
  bit auto_write [4];
  logic [12:0] open_row [4];
  logic [12:0] last_row [4];
  bit has_last_row [4];
  realtime t_active [4], t_ready [4], t_last_write [4];
  int unsigned pre_edge [4];
  realtime t_any_active, t_refresh, t_mode, t_last_refresh;
  int last_bank;
  int unsigned burst_end;
  bit write_phase [int unsigned];
  bit [25:0] write_key [int unsigned];
  int write_bank [int unsigned];
  bit read_phase [int unsigned];
  logic [15:0] read_word [int unsigned];
  logic [15:0] drive_value;
  logic [1:0] drive_enable;
  logic [1:0] dqm_hist [int unsigned];
  bit reading;
  int unsigned release_edge;

  assign dq[7:0] = drive_enable[0] ? drive_value[7:0] : 8'bz;
  assign dq[15:8] = drive_enable[1] ? drive_value[15:8] : 8'bz;

  task automatic fail(input string message);
    errors++;
    $error("SDRAM_MODEL %0t: %s", $realtime, message);
  endtask

  task automatic power_cycle();
    mem.delete();
    write_phase.delete(); write_key.delete(); write_bank.delete();
    read_phase.delete(); read_word.delete(); dqm_hist.delete();
    t_power = $realtime;
    init_step = 0; init_refreshes = 0; initialized = 0; refresh_late = 0;
    burst_length = 0; cas_latency = 0; burst_end = 0;
    for (int b = 0; b < 4; b++) begin
      active[b] = 0; auto_pending[b] = 0; auto_write[b] = 0; has_last_row[b] = 0;
      t_active[b] = -1.0e9; t_ready[b] = 0; t_last_write[b] = -1.0e9; pre_edge[b] = 0;
    end
    t_any_active = -1.0e9; t_refresh = -1.0e9; t_mode = -1.0e9; t_last_refresh = -1.0e9;
    last_bank = -1;
    drive_enable = 0; reading = 0; release_edge = 0;
  endtask
  initial begin last_edge = 0; last_change = 0; power_cycle(); end

  function automatic logic [7:0] read_byte(input bit [25:0] k);
    if (mem.exists(k)) return mem[k];
    return 8'(k * 37 + 8'h5a ^ (k >> 8));
  endfunction

  always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm) begin
    if (last_edge > 0 && $realtime - last_edge < T_HOLD) fail("input hold time violated");
    last_change = $realtime;
  end
  always @(dq) if (drive_enable == 0 && !reading) begin
    if (last_edge > 0 && $realtime - last_edge < T_HOLD) fail("DQ input hold time violated");
    last_change = $realtime;
  end

  task automatic schedule_output(input logic [15:0] value, input logic [1:0] enable, input bit last);
    fork begin
      #(T_OH) drive_value = 16'hxxxx;
      #(T_AC - T_OH) begin drive_value = value; drive_enable = enable; end
    end join_none
  endtask
  task automatic schedule_release();
    fork begin
      #(T_OH) drive_value = 16'hxxxx;
      #(T_HZ - T_OH) begin drive_enable = 0; reading = 0; end
    end join_none
  endtask

  always @(posedge clk) begin
    automatic realtime now = $realtime;
    automatic realtime period = now - last_edge;
    automatic logic [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    automatic int b = int'(ba);
    if (edge_no > 2 && cas_latency == 2 && period < T_CK_CL2 - 0.001) fail("tCK too short for CAS latency 2");
    if (edge_no > 2 && cas_latency == 3 && period < T_CK_CL3 - 0.001) fail("tCK too short for CAS latency 3");
    if (now - last_change < T_SETUP && edge_no > 0) fail("input setup time violated");
    last_edge = now;
    edge_no++;
    if (cke !== 1'b1) fail("CKE low or unknown: power-down/self-refresh is not modeled");
    dqm_hist[edge_no] = dqm;
    if (dqm_hist.exists(edge_no - 3)) dqm_hist.delete(edge_no - 3);

    if (write_phase.exists(edge_no)) begin
      for (int lane = 0; lane < 2; lane++) if (!dqm[lane]) begin
        if ($isunknown(dq[lane*8 +: 8])) fail("write data not driven on an unmasked byte");
        mem[write_key[edge_no] | 26'(lane)] = dq[lane*8 +: 8];
      end
      t_last_write[write_bank[edge_no]] = now;
      write_phase.delete(edge_no); write_key.delete(edge_no); write_bank.delete(edge_no);
    end
    if (read_phase.exists(edge_no)) begin
      automatic logic [1:0] mask = dqm_hist.exists(edge_no - 1) ? dqm_hist[edge_no - 1] : 2'b00;
      reading = 1;
      schedule_output(read_word[edge_no], ~mask, 0);
      read_phase.delete(edge_no); read_word.delete(edge_no);
      if (!read_phase.exists(edge_no + 1)) release_edge = edge_no + 1;
    end else if (release_edge == edge_no) schedule_release();
    for (int k = 0; k < 4; k++) if (auto_pending[k] && pre_edge[k] == edge_no) begin
      if (!auto_write[k]) begin
        if (now - t_active[k] < T_RAS - 0.001) fail($sformatf("tRAS violated by auto precharge (bank %0d)", k));
        t_ready[k] = now + T_RP;
      end
      auto_pending[k] = 0; active[k] = 0;
    end

    if (init_step == 0 && now - t_power < T_POWERUP) begin
      if (cs_n === 1'b0 && cmd !== 4'b0111) fail("command other than NOP/INHIBIT during the power-up wait");
      if (dqm !== 2'b11) fail("DQM not high during the power-up wait");
    end else if (cs_n === 1'b0) begin
      if (init_step == 0) init_step = 1;
      if ($isunknown({ras_n, cas_n, we_n})) fail("unknown command");
      else case (cmd)
        4'b0111: ;
        4'b0011: begin
          n_active++;
          if (init_step != 4) fail("ACTIVATE before initialization finished");
          if ($isunknown({ba, a})) fail("ACTIVATE with unknown bank/row");
          if (active[b] || auto_pending[b]) fail($sformatf("ACTIVATE to active bank %0d", b));
          if (now < t_ready[b] - 0.001) fail($sformatf("tRP/tDAL violated (bank %0d)", b));
          if (now - t_active[b] < T_RC - 0.001) fail($sformatf("tRC violated (bank %0d)", b));
          if (last_bank != b && now - t_any_active < T_RRD - 0.001) fail("tRRD violated");
          if (now - t_refresh < T_RC - 0.001) fail("REFRESH to ACTIVATE tRC violated");
          if (now - t_mode < T_MRD - 0.001) fail("tMRD violated");
          if (last_bank >= 0 && last_bank != b) n_bank_change++;
          if (has_last_row[b]) begin if (last_row[b] == a) n_row_same++; else n_row_change++; end
          active[b] = 1; open_row[b] = a; last_row[b] = a; has_last_row[b] = 1;
          t_active[b] = now; t_any_active = now; last_bank = b;
        end
        4'b0101, 4'b0100: begin
          automatic bit write = cmd == 4'b0100;
          automatic bit autopre = a[10];
          automatic logic [9:0] column = a[9:0];
          if (write) n_write++; else n_read++;
          if (init_step != 4) fail("READ/WRITE before initialization finished");
          if ($isunknown({ba, a[10:0]})) fail("READ/WRITE with unknown bank/column");
          if (!active[b] || auto_pending[b]) fail($sformatf("READ/WRITE to idle or precharging bank %0d", b));
          if (now - t_active[b] < T_RCD - 0.001) fail($sformatf("tRCD violated (bank %0d)", b));
          if (edge_no < burst_end) fail("burst interrupted (not modeled)");
          if (write && (reading || read_phase.size() != 0)) fail("WRITE while read data is on DQ (bus contention)");
          for (int i = 0; i < burst_length; i++) begin
            automatic logic [9:0] c = (column & ~10'(burst_length - 1)) | ((column + 10'(i)) & 10'(burst_length - 1));
            if (write) begin
              write_phase[edge_no + i] = 1; write_key[edge_no + i] = key(ba, open_row[b], c, 0); write_bank[edge_no + i] = b;
            end else begin
              read_phase[edge_no + cas_latency - 1 + i] = 1;
              read_word[edge_no + cas_latency - 1 + i] = {read_byte(key(ba, open_row[b], c, 1)), read_byte(key(ba, open_row[b], c, 0))};
            end
          end
          burst_end = edge_no + burst_length;
          if (write) begin
            for (int lane = 0; lane < 2; lane++) if (!dqm[lane]) begin
              if ($isunknown(dq[lane*8 +: 8])) fail("write data not driven on an unmasked byte");
              mem[write_key[edge_no] | 26'(lane)] = dq[lane*8 +: 8];
            end
            t_last_write[b] = now;
            write_phase.delete(edge_no); write_key.delete(edge_no); write_bank.delete(edge_no);
          end
          if (autopre) begin
            n_auto_precharge++;
            auto_pending[b] = 1;
            auto_write[b] = write;
            if (write) begin
              automatic realtime t_last = now + (burst_length - 1) * period;
              automatic realtime dpl = 2 * period > T_DPL ? 2 * period : T_DPL;
              if (t_last + dpl - t_active[b] < T_RAS - 0.001) fail($sformatf("tRAS violated by write auto precharge (bank %0d)", b));
              t_ready[b] = t_last + (dpl + T_RP > T_DAL ? dpl + T_RP : T_DAL);
              pre_edge[b] = edge_no + burst_length;
            end else pre_edge[b] = edge_no + burst_length;
          end
        end
        4'b0010: begin
          n_precharge++;
          if (init_step == 1) begin
            if (a[10] !== 1'b1) fail("initialization must start with PRECHARGE ALL");
            init_step = 2;
          end else if (init_step != 4) fail("PRECHARGE out of initialization order");
          for (int k = 0; k < 4; k++) if (a[10] || k == b) begin
            if (auto_pending[k]) fail($sformatf("PRECHARGE during auto precharge (bank %0d)", k));
            if (active[k]) begin
              if (now - t_active[k] < T_RAS - 0.001) fail($sformatf("tRAS violated (bank %0d)", k));
              if (now - t_last_write[k] < (2 * period > T_DPL ? 2 * period : T_DPL) - 0.001) fail($sformatf("tDPL violated (bank %0d)", k));
              active[k] = 0;
            end
            if (t_ready[k] < now + T_RP) t_ready[k] = now + T_RP;
          end
        end
        4'b0001: begin
          n_refresh++;
          for (int k = 0; k < 4; k++) begin
            if (active[k] || auto_pending[k]) fail($sformatf("REFRESH with bank %0d active", k));
            if (now < t_ready[k] - 0.001) fail($sformatf("REFRESH before tRP/tDAL (bank %0d)", k));
          end
          if (now - t_refresh < T_RC - 0.001) fail("REFRESH to REFRESH tRC violated");
          if (now - t_any_active < T_RC - 0.001) fail("ACTIVATE to REFRESH tRC violated");
          if (now - t_mode < T_MRD - 0.001) fail("tMRD violated");
          if (init_step == 2) init_refreshes++;
          else if (init_step == 4) begin
            if (now - t_last_refresh > T_REFI_MAX) fail($sformatf("refresh gap %0.1f ns exceeds %0.1f ns", now - t_last_refresh, T_REFI_MAX));
            if (now - t_last_refresh > max_refresh_gap) max_refresh_gap = now - t_last_refresh;
          end else fail("REFRESH out of initialization order");
          t_refresh = now; t_last_refresh = now; refresh_late = 0;
        end
        4'b0000: begin
          n_mode++;
          if (init_step == 2 && init_refreshes >= INIT_REFRESHES) init_step = 3;
          if (init_step != 3 && init_step != 4) fail("LOAD MODE before PRECHARGE ALL and the initial refreshes");
          for (int k = 0; k < 4; k++) if (active[k] || auto_pending[k] || now < t_ready[k] - 0.001)
            fail("LOAD MODE with a bank not idle");
          if (now - t_refresh < T_RC - 0.001) fail("REFRESH to LOAD MODE tRC violated");
          if ({ba, a[12:10]} !== 5'b0) fail("LOAD MODE reserved bits (BA, A12-A10) not zero");
          if (a[9] !== 1'b0) fail("single-location write mode is not modeled");
          if (a[8:7] !== 2'b00) fail("reserved operating mode");
          if (a[3] !== 1'b0) fail("interleaved bursts are not modeled");
          case (a[2:0]) 3'd0: burst_length = 1; 3'd1: burst_length = 2; 3'd2: burst_length = 4; 3'd3: burst_length = 8;
            default: begin burst_length = 1; fail("unsupported burst length"); end endcase
          case (a[6:4]) 3'd2: cas_latency = 2; 3'd3: cas_latency = 3;
            default: begin cas_latency = 2; fail("unsupported CAS latency"); end endcase
          t_mode = now;
          if (init_step == 3) begin
            init_step = 4; initialized = 1;
          end
        end
        4'b0110: fail("BURST TERMINATE is not modeled");
        default: fail("unknown command");
      endcase
    end
    for (int k = 0; k < 4; k++) if (active[k] && now - t_active[k] > T_RAS_MAX) fail("tRAS maximum exceeded");
    if (initialized && !refresh_late && now - t_last_refresh > T_REFI_MAX) begin
      refresh_late = 1;
      fail($sformatf("no REFRESH for %0.1f ns (limit %0.1f ns)", now - t_last_refresh, T_REFI_MAX));
    end
  end

  task automatic dump(input string path);
    int fd = $fopen(path, "w");
    foreach (mem[k]) $fdisplay(fd, "%0d %0d %0d %0d %02h", k[25:24], k[23:11], k[10:1], k[0], mem[k]);
    $fclose(fd);
  endtask
  function automatic logic [7:0] peek(input logic [1:0] b, input logic [12:0] r, input logic [9:0] c, input bit hi);
    return read_byte(key(b, r, c, hi));
  endfunction
  function automatic bit written(input logic [1:0] b, input logic [12:0] r, input logic [9:0] c, input bit hi);
    return mem.exists(key(b, r, c, hi));
  endfunction
endmodule
