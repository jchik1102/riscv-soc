package cpu_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import soc_pkg::*;

  localparam longint unsigned RAM_BASE = platform_pkg::RAM_BASE;
  localparam int RAM_SIZE = int'(platform_pkg::RAM_BYTES);
  localparam longint unsigned RESET_PC = platform_pkg::RESET_PC;
  typedef byte unsigned byte_array_t[];

  class cpu_uvm_ctrl;
    static bit rst_request = 1;
    static function byte_array_t read_image(string path);
      byte_array_t image = new[RAM_SIZE];
      string token;
      int fd = $fopen(path, "r"), address = 0, last = 0;
      if (fd == 0) `uvm_fatal("IMAGE", {"cannot open ", path})
      while ($fscanf(fd, "%s", token) == 1) begin
        if (token.getc(0) == "@") address = token.substr(1, token.len() - 1).atohex();
        else begin image[address] = 8'(token.atohex()); address++; if (address > last) last = address; end
      end
      $fclose(fd);
      image = new[last](image);
      return image;
    endfunction
  endclass

  class mem_model extends uvm_object;
    `uvm_object_utils(mem_model)
    byte unsigned data[];
    function new(string name = "mem_model"); super.new(name); data = new[RAM_SIZE]; endfunction
    static function bit beat_ok(bit [63:0] addr);
      return addr >= RAM_BASE && addr <= RAM_BASE + RAM_SIZE - 8 && addr[2:0] == 0;
    endfunction
    function void load(byte_array_t image);
      foreach (data[i]) data[i] = i < image.size() ? image[i] : 8'h00;
    endfunction
    function bit [63:0] read_beat(bit [63:0] addr, bit [7:0] mask);
      bit [63:0] value = 0;
      for (int lane = 0; lane < 8; lane++)
        if (mask[lane]) value[8*lane +: 8] = data[addr - RAM_BASE + lane];
      return value;
    endfunction
    function void write_beat(bit [63:0] addr, bit [7:0] mask, bit [63:0] wdata);
      for (int lane = 0; lane < 8; lane++)
        if (mask[lane]) data[addr - RAM_BASE + lane] = wdata[8*lane +: 8];
    endfunction
  endclass

  typedef enum {BUS_REQ, BUS_RSP} bus_phase_e;
  class bus_item extends uvm_sequence_item;
    `uvm_object_utils(bus_item)
    bit fetch_port;
    bus_phase_e phase;
    bit [63:0] addr, wdata, rdata;
    bit write, error;
    bit [7:0] mask;
    int unsigned waited;
    function new(string name = "bus_item"); super.new(name); endfunction
  endclass

  class retire_item extends uvm_sequence_item;
    `uvm_object_utils(retire_item)
    bit is_reset;
    retire_t rec;
    function new(string name = "retire_item"); super.new(name); endfunction
  endclass

  class event_item extends uvm_sequence_item;
    `uvm_object_utils(event_item)
    bit mem_wait, arith_wait, fetch_wait, load_use, redirect, retired;
    function new(string name = "event_item"); super.new(name); endfunction
  endclass

  class bus_timing extends uvm_sequence_item;
    `uvm_object_utils(bus_timing)
    int unsigned max_delay = 5;
    bit always_ready = 0;
    rand int unsigned delay;
    rand bit ready;
    constraint c_delay { delay <= max_delay; delay dist {0 := 3, [1:3] := 2, [4:100] := 1}; }
    constraint c_ready { if (always_ready) ready == 1; else ready dist {1 := 2, 0 := 1}; }
    function new(string name = "bus_timing"); super.new(name); endfunction
  endclass

  class mem_agent_cfg extends uvm_object;
    `uvm_object_utils(mem_agent_cfg)
    bit fetch_port;
    int unsigned max_delay = 5;
    bit always_ready = 0;
    function new(string name = "mem_agent_cfg"); super.new(name); endfunction
  endclass

  class mem_responder extends uvm_component;
    `uvm_component_utils(mem_responder)
    virtual bus_if vif;
    mem_agent_cfg cfg;
    mem_model mem;
    bus_timing timing;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      timing = bus_timing::type_id::create("timing");
    endfunction
    function bit next_ready();
      timing.max_delay = cfg.max_delay; timing.always_ready = cfg.always_ready;
      if (!timing.randomize()) `uvm_fatal("RESP", "timing randomize failed")
      return timing.ready;
    endfunction
    task run_phase(uvm_phase phase);
      bit busy = 0, responding = 0;
      int unsigned delay;
      bus_req_t saved;
      bus_rsp_t rsp;
      vif.req_ready <= 0; vif.rsp_valid <= 0; vif.rsp <= '0;
      forever begin
        @(posedge vif.clk);
        if (vif.rst) begin busy = 0; responding = 0; end
        else begin
          if (responding && vif.rsp_ready) begin responding = 0; busy = 0; end
          if (vif.req_valid && vif.req_ready) begin
            saved = vif.req; busy = 1;
            if (saved.write && mem_model::beat_ok(saved.addr)) mem.write_beat(saved.addr, saved.mask, saved.wdata);
            void'(next_ready());
            delay = timing.delay;
          end else if (busy && !responding) begin
            if (delay != 0) delay--;
          end
          if (busy && !responding && delay == 0) begin
            responding = 1;
            rsp = '0;
            if (!mem_model::beat_ok(saved.addr) || (cfg.fetch_port && saved.write)) rsp.error = 1;
            else if (!saved.write) rsp.rdata = mem.read_beat(saved.addr, saved.mask);
          end
        end
        @(negedge vif.clk);
        vif.rsp_valid <= responding && !vif.rst;
        vif.rsp <= responding ? rsp : '0;
        vif.req_ready <= !vif.rst && !busy && next_ready();
      end
    endtask
  endclass

  class bus_monitor extends uvm_component;
    `uvm_component_utils(bus_monitor)
    virtual bus_if vif;
    bit fetch_port;
    uvm_analysis_port #(bus_item) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    task run_phase(uvm_phase phase);
      int unsigned waited = 0, latency = 0;
      bit outstanding = 0;
      forever begin
        @(posedge vif.clk);
        if (vif.rst) begin waited = 0; outstanding = 0; continue; end
        if (outstanding) latency++;
        if (vif.rsp_valid && vif.rsp_ready) begin
          bus_item item = bus_item::type_id::create("rsp");
          item.fetch_port = fetch_port; item.phase = BUS_RSP;
          item.error = vif.rsp.error; item.rdata = vif.rsp.rdata; item.waited = latency;
          outstanding = 0;
          ap.write(item);
        end
        if (vif.req_valid && !vif.req_ready) waited++;
        if (vif.req_valid && vif.req_ready) begin
          bus_item item = bus_item::type_id::create("req");
          item.fetch_port = fetch_port; item.phase = BUS_REQ;
          item.addr = vif.req.addr; item.write = vif.req.write; item.mask = vif.req.mask;
          item.wdata = vif.req.wdata; item.waited = waited;
          waited = 0; outstanding = 1; latency = 0;
          ap.write(item);
        end
      end
    endtask
  endclass

  class mem_agent extends uvm_component;
    `uvm_component_utils(mem_agent)
    mem_responder responder;
    bus_monitor monitor;
    mem_agent_cfg cfg;
    virtual bus_if vif;
    mem_model mem;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(mem_agent_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("AGENT", "no cfg")
      if (!uvm_config_db#(virtual bus_if)::get(this, "", "vif", vif)) `uvm_fatal("AGENT", "no vif")
      if (!uvm_config_db#(mem_model)::get(this, "", "mem", mem)) `uvm_fatal("AGENT", "no mem")
      responder = mem_responder::type_id::create("responder", this);
      monitor = bus_monitor::type_id::create("monitor", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      responder.vif = vif; responder.cfg = cfg; responder.mem = mem;
      monitor.vif = vif; monitor.fetch_port = cfg.fetch_port;
    endfunction
  endclass

  class retire_monitor extends uvm_component;
    `uvm_component_utils(retire_monitor)
    virtual retire_if vif;
    uvm_analysis_port #(retire_item) ap;
    uvm_analysis_port #(event_item) events_ap;
    longint unsigned cycles;
    function new(string name, uvm_component parent);
      super.new(name, parent); ap = new("ap", this); events_ap = new("events_ap", this);
    endfunction
    task run_phase(uvm_phase phase);
      bit was_reset = 1;
      forever begin
        @(posedge vif.clk);
        if (vif.rst) begin
          if (!was_reset) begin
            retire_item marker = retire_item::type_id::create("reset");
            marker.is_reset = 1;
            ap.write(marker);
          end
          was_reset = 1;
          continue;
        end
        if (was_reset) begin
          retire_item marker = retire_item::type_id::create("reset");
          marker.is_reset = 1;
          ap.write(marker);
          was_reset = 0;
        end
        cycles++;
        begin
          event_item e = event_item::type_id::create("ev");
          e.mem_wait = vif.event_mem_wait; e.arith_wait = vif.event_arith_wait; e.fetch_wait = vif.event_fetch_wait;
          e.load_use = vif.event_load_use; e.redirect = vif.event_redirect; e.retired = vif.event_retired;
          events_ap.write(e);
        end
        if (vif.trace_valid) begin
          retire_item item = retire_item::type_id::create("retire");
          item.rec = vif.trace;
          ap.write(item);
        end
      end
    endtask
  endclass

  class rv64im_iss;
    bit [63:0] x[32];
    bit [63:0] pc;
    longint unsigned order;
    bit halted;
    byte unsigned mem[];
    string last_name;
    bit mie_b, mpie_b;
    bit [63:0] csr_mie, mtvec, mscratch, mepc, mcause, mtval, minstret, ext_value, t_target, t_addr;
    bit minstret_written, ext_used;
    bit [31:0] t_insn;
    function new(); mem = new[RAM_SIZE]; endfunction
    function void reset_from(byte unsigned phys[]);
      foreach (x[i]) x[i] = 0;
      pc = RESET_PC; order = 0; halted = 0;
      mie_b = 0; mpie_b = 0; csr_mie = 0; mtvec = 0; mscratch = 0; mepc = 0; mcause = 0; mtval = 0; minstret = 0;
      foreach (mem[i]) mem[i] = phys[i];
    endfunction
    function void copy_from(rv64im_iss other);
      x = other.x; pc = other.pc; order = other.order; halted = other.halted;
      mie_b = other.mie_b; mpie_b = other.mpie_b; csr_mie = other.csr_mie; mtvec = other.mtvec;
      mscratch = other.mscratch; mepc = other.mepc; mcause = other.mcause; mtval = other.mtval; minstret = other.minstret;
      foreach (mem[i]) mem[i] = other.mem[i];
    endfunction
    function bit csr_read(bit [11:0] a, output bit [63:0] v);
      case (a)
        12'h300: v = {51'b0, 2'b11, 3'b0, mpie_b, 3'b0, mie_b, 3'b0};
        12'h301: v = 64'h8000000000001100;
        12'h304: v = csr_mie;
        12'h305: v = mtvec;
        12'h340: v = mscratch;
        12'h341: v = mepc;
        12'h342: v = mcause;
        12'h343: v = mtval;
        12'h344, 12'hb00: begin v = ext_value; ext_used = 1; end
        12'hb02: v = minstret;
        12'hf11, 12'hf12, 12'hf13, 12'hf14: v = 0;
        default: return 0;
      endcase
      return 1;
    endfunction
    function void csr_write(bit [11:0] a, bit [63:0] v);
      case (a)
        12'h300: begin mie_b = v[3]; mpie_b = v[7]; end
        12'h304: csr_mie = v & 64'h888;
        12'h305: mtvec = {v[63:2], 2'b00};
        12'h340: mscratch = v;
        12'h341: mepc = {v[63:2], 2'b00};
        12'h342: mcause = v;
        12'h343: mtval = v;
        12'hb02: begin minstret = v; minstret_written = 1; end
        default: begin end
      endcase
    endfunction
    function bit fits(bit [63:0] addr, int size);
      return addr >= RAM_BASE && addr - RAM_BASE <= RAM_SIZE - size;
    endfunction
    function bit [63:0] read_le(bit [63:0] addr, int size);
      bit [63:0] v = 0;
      for (int i = 0; i < size; i++) v[8*i +: 8] = mem[addr - RAM_BASE + i];
      return v;
    endfunction
    static function bit [63:0] sext32(bit [31:0] v); return {{32{v[31]}}, v}; endfunction
    static function bit [63:0] m_result(bit [2:0] f3, bit word, bit [63:0] a, bit [63:0] b);
      bit [127:0] p;
      bit [63:0] x, y, q, r;
      bit is_signed = f3 == 4 || f3 == 6;
      if (!word) begin
        case (f3)
          0: return a * b;
          1: begin p = $signed({{64{a[63]}}, a}) * $signed({{64{b[63]}}, b}); return p[127:64]; end
          2: begin p = $signed({{64{a[63]}}, a}) * $signed({64'b0, b}); return p[127:64]; end
          3: begin p = {64'b0, a} * {64'b0, b}; return p[127:64]; end
        endcase
        x = a; y = b;
      end else begin
        if (f3 == 0) begin q = a[31:0] * b[31:0]; return sext32(q[31:0]); end
        x = is_signed ? sext32(a[31:0]) : {32'b0, a[31:0]};
        y = is_signed ? sext32(b[31:0]) : {32'b0, b[31:0]};
      end
      if (y == 0) begin q = '1; r = x; end
      else if (is_signed && !word && x == 64'h8000000000000000 && y == '1) begin q = x; r = 0; end
      else if (is_signed) begin q = $signed(x) / $signed(y); r = $signed(x) % $signed(y); end
      else begin q = x / y; r = x % y; end
      p[63:0] = (f3 == 4 || f3 == 5) ? q : r;
      return word ? sext32(p[31:0]) : p[63:0];
    endfunction
    function retire_t trap(retire_t r, int cause);
      bit [63:0] tval;
      case (cause)
        0: tval = pc[1:0] != 0 ? pc : t_target;
        1, 3: tval = pc;
        2: tval = {32'b0, t_insn};
        4, 5, 6, 7: tval = t_addr;
        default: tval = 0;
      endcase
      r.trap = 1; r.cause = 6'(cause); r.rd = 0; r.rd_data = 0; r.mem_rdata = 0;
      if (mtvec == 0) begin r.next_pc = pc; halted = 1; end
      else begin
        mepc = {pc[63:2], 2'b00}; mcause = cause; mtval = tval; mpie_b = mie_b; mie_b = 0;
        r.next_pc = mtvec; pc = mtvec;
      end
      order++;
      return r;
    endfunction
    function retire_t step();
      retire_t r = '0;
      bit [31:0] in;
      bit [6:0] opcode, f7;
      bit [4:0] rd, rs1, rs2;
      bit [2:0] f3;
      bit [63:0] a, b, iimm, simm, bimm, jimm, uimm, value, target, addr, raw;
      bit [31:0] w;
      bit writes = 0, ok = 1;
      int size;
      if (halted) `uvm_fatal("ISS", "stepped after terminal diagnostic")
      r.order = order; r.pc = pc; r.next_pc = pc + 4;
      last_name = "TRAP";
      t_insn = 0;
      if (pc[1:0] != 0) return trap(r, 0);
      if (!fits(pc, 4)) return trap(r, 1);
      in = read_le(pc, 4); r.insn = in; t_insn = in; minstret_written = 0;
      opcode = in[6:0]; rd = in[11:7]; f3 = in[14:12]; rs1 = in[19:15]; rs2 = in[24:20]; f7 = in[31:25];
      a = x[rs1]; b = x[rs2];
      iimm = {{52{in[31]}}, in[31:20]};
      simm = {{52{in[31]}}, in[31:25], in[11:7]};
      bimm = {{51{in[31]}}, in[31], in[7], in[30:25], in[11:8], 1'b0};
      jimm = {{43{in[31]}}, in[31], in[19:12], in[20], in[30:21], 1'b0};
      uimm = {{32{in[31]}}, in[31:12], 12'b0};
      case (opcode)
        7'h37: begin writes = 1; value = uimm; last_name = "LUI"; end
        7'h17: begin writes = 1; value = pc + uimm; last_name = "AUIPC"; end
        7'h6f: begin
          target = pc + jimm; last_name = "JAL";
          if (target[1:0] != 0) begin t_target = target; return trap(r, 0); end
          writes = 1; value = pc + 4; r.next_pc = target;
        end
        7'h67: begin
          if (f3 != 0) return trap(r, 2);
          target = (a + iimm) & ~64'd1; last_name = "JALR";
          if (target[1:0] != 0) begin t_target = target; return trap(r, 0); end
          writes = 1; value = pc + 4; r.next_pc = target;
        end
        7'h63: begin
          bit taken;
          case (f3)
            0: taken = a == b;
            1: taken = a != b;
            4: taken = $signed(a) < $signed(b);
            5: taken = $signed(a) >= $signed(b);
            6: taken = a < b;
            7: taken = a >= b;
            default: return trap(r, 2);
          endcase
          last_name = taken ? "BRANCH_T" : "BRANCH_N";
          if (taken) begin
            target = pc + bimm;
            if (target[1:0] != 0) begin t_target = target; return trap(r, 0); end
            r.next_pc = target;
          end
        end
        7'h03: begin
          if (f3 == 7) return trap(r, 2);
          size = 1 << f3[1:0]; addr = a + iimm; t_addr = addr; last_name = "LOAD";
          if (addr % size != 0) return trap(r, 4);
          r.mem_addr = addr; r.mem_rmask = 8'((1 << size) - 1) << addr[2:0];
          if (!fits(addr, size)) return trap(r, 5);
          raw = read_le(addr, size);
          r.mem_rdata = raw << (8 * addr[2:0]);
          case (f3)
            0: value = {{56{raw[7]}}, raw[7:0]};
            1: value = {{48{raw[15]}}, raw[15:0]};
            2: value = {{32{raw[31]}}, raw[31:0]};
            default: value = raw;
          endcase
          writes = 1;
        end
        7'h23: begin
          bit [63:0] data;
          if (f3 > 3) return trap(r, 2);
          size = 1 << f3[1:0]; addr = a + simm; t_addr = addr; last_name = "STORE";
          if (addr % size != 0) return trap(r, 6);
          data = size == 8 ? b : b & ((64'd1 << (8 * size)) - 1);
          r.mem_addr = addr; r.mem_wmask = 8'((1 << size) - 1) << addr[2:0];
          r.mem_wdata = data << (8 * addr[2:0]);
          if (!fits(addr, size)) return trap(r, 7);
          for (int i = 0; i < size; i++) mem[addr - RAM_BASE + i] = data[8*i +: 8];
        end
        7'h13: begin
          writes = 1; last_name = "ALUI";
          case (f3)
            0: value = a + iimm;
            2: value = 64'($signed(a) < $signed(iimm));
            3: value = 64'(a < iimm);
            4: value = a ^ iimm;
            6: value = a | iimm;
            7: value = a & iimm;
            1: begin if (in[31:26] != 0) return trap(r, 2); value = a << in[25:20]; end
            default: begin
              if (in[31:26] == 6'h00) value = a >> in[25:20];
              else if (in[31:26] == 6'h10) value = $signed(a) >>> in[25:20];
              else return trap(r, 2);
            end
          endcase
        end
        7'h1b: begin
          writes = 1; last_name = "ALUIW";
          case (f3)
            0: w = a[31:0] + iimm[31:0];
            1: begin if (f7 != 0) return trap(r, 2); w = a[31:0] << in[24:20]; end
            5: begin
              if (f7 == 7'h00) w = a[31:0] >> in[24:20];
              else if (f7 == 7'h20) w = $signed(a[31:0]) >>> in[24:20];
              else return trap(r, 2);
            end
            default: return trap(r, 2);
          endcase
          value = sext32(w);
        end
        7'h33: begin
          writes = 1; last_name = "ALU";
          if (f7 == 7'h01) begin value = m_result(f3, 0, a, b); last_name = "M"; end
          else if (f7 == 7'h00) case (f3)
            0: value = a + b;
            1: value = a << b[5:0];
            2: value = 64'($signed(a) < $signed(b));
            3: value = 64'(a < b);
            4: value = a ^ b;
            5: value = a >> b[5:0];
            6: value = a | b;
            default: value = a & b;
          endcase
          else if (f7 == 7'h20 && f3 == 0) value = a - b;
          else if (f7 == 7'h20 && f3 == 5) value = $signed(a) >>> b[5:0];
          else return trap(r, 2);
        end
        7'h3b: begin
          writes = 1; last_name = "ALUW";
          if (f7 == 7'h01) begin
            if (f3 inside {1, 2, 3}) return trap(r, 2);
            value = m_result(f3, 1, a, b); last_name = "MW";
          end else begin
            if (f7 == 7'h00 && f3 == 0) w = a[31:0] + b[31:0];
            else if (f7 == 7'h20 && f3 == 0) w = a[31:0] - b[31:0];
            else if (f7 == 7'h00 && f3 == 1) w = a[31:0] << b[4:0];
            else if (f7 == 7'h00 && f3 == 5) w = a[31:0] >> b[4:0];
            else if (f7 == 7'h20 && f3 == 5) w = $signed(a[31:0]) >>> b[4:0];
            else return trap(r, 2);
            value = sext32(w);
          end
        end
        7'h0f: begin if (f3 > 1) return trap(r, 2); if (f3 == 1) last_name = "FENCE.I"; else last_name = "FENCE"; end
        7'h73: begin
          bit [63:0] old, operand;
          bit write_intent;
          if (in == 32'h00000073) return trap(r, 11);
          if (in == 32'h00100073) return trap(r, 3);
          if (in == 32'h30200073) begin
            r.next_pc = mepc; mie_b = mpie_b; mpie_b = 1; last_name = "MRET";
          end else if (in == 32'h10500073) last_name = "WFI";
          else begin
            if (f3[1:0] == 0) return trap(r, 2);
            operand = f3[2] ? {59'b0, rs1} : a;
            write_intent = f3[1:0] == 2'b01 || rs1 != 0;
            if (!csr_read(in[31:20], old) || (in[31:30] == 2'b11 && write_intent)) return trap(r, 2);
            if (write_intent) csr_write(in[31:20], f3[1:0] == 1 ? operand : f3[1:0] == 2 ? old | operand : old & ~operand);
            writes = 1; value = old; last_name = "CSR";
          end
        end
        default: return trap(r, 2);
      endcase
      if (writes && rd != 0) begin r.rd = rd; r.rd_data = value; x[rd] = value; end
      if (!minstret_written) minstret++;
      pc = r.next_pc;
      order++;
      return r;
    endfunction
  endclass

  `uvm_analysis_imp_decl(_fetch)
  `uvm_analysis_imp_decl(_data)
  `uvm_analysis_imp_decl(_retire)

  class cpu_scoreboard extends uvm_component;
    `uvm_component_utils(cpu_scoreboard)
    uvm_analysis_imp_fetch #(bus_item, cpu_scoreboard) fetch_imp;
    uvm_analysis_imp_data #(bus_item, cpu_scoreboard) data_imp;
    uvm_analysis_imp_retire #(retire_item, cpu_scoreboard) retire_imp;
    bit unified;
    rv64im_iss model, ahead;
    mem_model phys;
    mem_model env_mem;
    longint unsigned issued[$];
    bit issued_rsp[$];
    bit fetch_out, data_out, exp_data_error;
    bit [63:0] fetch_addr, exp_rdata;
    int unsigned retired, fetches, accesses, mismatches, resets, programs_passed;
    bit terminal;
    uvm_event terminal_ev;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      fetch_imp = new("fetch_imp", this); data_imp = new("data_imp", this); retire_imp = new("retire_imp", this);
      model = new(); ahead = new(); phys = mem_model::type_id::create("phys"); terminal_ev = new("terminal");
    endfunction
    function void load_program(byte_array_t image);
      phys.load(image); terminal = 0;
      model.reset_from(phys.data); ahead.copy_from(model);
    endfunction
    function void fail(string message);
      mismatches++;
      `uvm_error("SCOREBOARD", message)
    endfunction
    function void write_fetch(bus_item t);
      if (unified) begin write_unified(t); return; end
      if (t.phase == BUS_REQ) begin
        if (fetch_out) fail("second outstanding fetch");
        if (t.write || t.mask != 8'hff || t.wdata != 0 || t.addr[2:0] != 0) fail($sformatf("malformed fetch %h", t.addr));
        fetch_out = 1; fetch_addr = t.addr; fetches++;
      end else begin
        bit exp_error = !mem_model::beat_ok(fetch_addr);
        bit [63:0] expected = exp_error ? 0 : phys.read_beat(fetch_addr, 8'hff);
        if (!fetch_out) fail("fetch response without request");
        else if (t.error != exp_error || t.rdata != expected)
          fail($sformatf("fetch %h: expected %0d/%h actual %0d/%h", fetch_addr, exp_error, expected, t.error, t.rdata));
        fetch_out = 0;
      end
    endfunction
    function void write_unified(bus_item t);
      if (t.phase == BUS_REQ && t.write && mem_model::beat_ok(t.addr)) phys.write_beat(t.addr, t.mask, t.wdata);
      if (t.phase == BUS_REQ) accesses++;
    endfunction
    function void write_data(bus_item t);
      if (t.phase == BUS_REQ) begin
        retire_t row;
        bit [7:0] mask;
        if (data_out) fail("second outstanding data request");
        do begin
          if (ahead.halted) begin fail($sformatf("data request %h after predicted end (wrong-path or extra)", t.addr)); return; end
          row = ahead.step();
        end while (row.mem_rmask == 0 && row.mem_wmask == 0);
        mask = row.mem_wmask != 0 ? row.mem_wmask : row.mem_rmask;
        if (t.addr != {row.mem_addr[63:3], 3'b0} || t.write != (row.mem_wmask != 0) || t.mask != mask || t.wdata != row.mem_wdata)
          fail($sformatf("data request order %0d: expected %h/%0d/%h/%h actual %h/%0d/%h/%h", row.order,
               {row.mem_addr[63:3], 3'b0}, row.mem_wmask != 0, mask, row.mem_wdata, t.addr, t.write, t.mask, t.wdata));
        exp_data_error = !mem_model::beat_ok(t.addr);
        exp_rdata = 0;
        if (!exp_data_error) begin
          if (t.write) phys.write_beat(t.addr, t.mask, t.wdata);
          else exp_rdata = phys.read_beat(t.addr, t.mask);
        end
        issued.push_back(row.order); issued_rsp.push_back(0);
        data_out = 1; accesses++;
      end else begin
        if (!data_out) fail("data response without request");
        else if (t.error != exp_data_error || t.rdata != exp_rdata)
          fail($sformatf("data response: expected %0d/%h actual %0d/%h", exp_data_error, exp_rdata, t.error, t.rdata));
        if (issued_rsp.size() != 0) issued_rsp[issued_rsp.size() - 1] = 1;
        data_out = 0;
      end
    endfunction
    function void write_retire(retire_item t);
      retire_t expected;
      if (t.is_reset) begin
        resets++;
        model.reset_from(phys.data); ahead.copy_from(model);
        issued.delete(); issued_rsp.delete(); fetch_out = 0; data_out = 0; terminal = 0;
        return;
      end
      if (model.halted) begin fail("retirement after predicted terminal diagnostic"); return; end
      model.ext_value = t.rec.rd_data;
      expected = model.step();
      if (t.rec != expected)
        fail($sformatf("retirement %0d: expected pc=%h insn=%h next=%h rd=%0d val=%h addr=%h r/w=%h/%h rd=%h wd=%h trap=%0d/%0d; actual pc=%h insn=%h next=%h rd=%0d val=%h addr=%h r/w=%h/%h rd=%h wd=%h trap=%0d/%0d",
          expected.order, expected.pc, expected.insn, expected.next_pc, expected.rd, expected.rd_data, expected.mem_addr,
          expected.mem_rmask, expected.mem_wmask, expected.mem_rdata, expected.mem_wdata, expected.trap, expected.cause,
          t.rec.pc, t.rec.insn, t.rec.next_pc, t.rec.rd, t.rec.rd_data, t.rec.mem_addr, t.rec.mem_rmask, t.rec.mem_wmask,
          t.rec.mem_rdata, t.rec.mem_wdata, t.rec.trap, t.rec.cause));
      if (!unified && (expected.mem_rmask != 0 || expected.mem_wmask != 0)) begin
        if (issued.size() == 0 || issued[0] != expected.order) fail($sformatf("instruction %0d retired without its data access", expected.order));
        else if (!issued_rsp[0]) fail($sformatf("instruction %0d retired before its response", expected.order));
        else begin void'(issued.pop_front()); void'(issued_rsp.pop_front()); end
      end
      if (!expected.trap) retired++;
      else if (model.halted) begin
        terminal = 1;
        terminal_ev.trigger();
      end
    endfunction
    function void end_of_program(string name);
      if (!unified && issued.size() != 0) fail("data access issued but never retired");
      foreach (phys.data[i]) if (phys.data[i] != env_mem.data[i]) begin
        fail($sformatf("final RAM differs at offset %h", i)); break;
      end
      foreach (phys.data[i]) if (phys.data[i] != model.mem[i]) begin
        fail($sformatf("predicted physical RAM differs from architectural RAM at %h", i)); break;
      end
      if (mismatches == 0) programs_passed++;
      `uvm_info("SCOREBOARD", $sformatf("%s: retired=%0d fetches=%0d accesses=%0d resets=%0d mismatches=%0d",
                name, retired, fetches, accesses, resets, mismatches), UVM_LOW)
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("SCOREBOARD", $sformatf("SCOREBOARD_SUMMARY programs_passed=%0d retired=%0d fetches=%0d data_accesses=%0d resets=%0d mismatches=%0d",
                programs_passed, retired, fetches, accesses, resets, mismatches), UVM_NONE)
    endfunction
  endclass

  typedef enum {C_ALU_R, C_ALU_I, C_ALU_W, C_ALU_IW, C_LUI, C_AUIPC, C_JAL, C_JALR, C_BR_TAKEN, C_BR_NOT,
                C_LOAD, C_STORE, C_M, C_M_W, C_FENCE, C_TRAP, C_SYS} insn_class_e;

  `uvm_analysis_imp_decl(_bus)
  `uvm_analysis_imp_decl(_event)
  class cpu_coverage extends uvm_component;
    `uvm_component_utils(cpu_coverage)
    uvm_analysis_imp_retire #(retire_item, cpu_coverage) retire_imp;
    uvm_analysis_imp_bus #(bus_item, cpu_coverage) bus_imp;
    uvm_analysis_imp_event #(event_item, cpu_coverage) event_imp;
    insn_class_e cls;
    bit [2:0] f3;
    int dist1, dist2;
    bit rd_zero, uses_rs2;
    bit [5:0] cause;
    longint unsigned last_write[32];
    longint unsigned count;
    bit b_fetch, b_write, b_error;
    int unsigned b_latency, b_wait;
    event_item ev;
    covergroup cg_retire;
      option.per_instance = 1;
      cp_class: coverpoint cls;
      cp_f3: coverpoint f3;
      cp_dist_rs1: coverpoint dist1 { bins none = {0}; bins d1 = {1}; bins d2 = {2}; bins d3 = {3}; }
      cp_dist_rs2: coverpoint dist2 iff (uses_rs2) { bins none = {0}; bins d1 = {1}; bins d2 = {2}; bins d3 = {3}; }
      cp_rd_zero: coverpoint rd_zero;
      cp_cause: coverpoint cause iff (cls == C_TRAP) { bins causes[] = {0, 1, 2, 3, 4, 5, 6, 7, 11}; }
      x_m_ops: cross cp_class, cp_f3 {
        ignore_bins other = !binsof(cp_class) intersect {C_M, C_M_W};
        ignore_bins mw_reserved = binsof(cp_class) intersect {C_M_W} && binsof(cp_f3) intersect {1, 2, 3}; }
      x_hazard_rs1: cross cp_class, cp_dist_rs1 {
        ignore_bins no_rs1 = binsof(cp_class) intersect {C_LUI, C_AUIPC, C_JAL, C_FENCE, C_TRAP}; }
      x_hazard_rs2: cross cp_class, cp_dist_rs2 {
        ignore_bins no_rs2 = !binsof(cp_class) intersect {C_ALU_R, C_ALU_W, C_BR_TAKEN, C_BR_NOT, C_STORE, C_M, C_M_W}; }
    endgroup
    covergroup cg_bus;
      option.per_instance = 1;
      cp_port: coverpoint b_fetch;
      cp_write: coverpoint b_write iff (!b_fetch);
      cp_error: coverpoint b_error;
      cp_latency: coverpoint b_latency { illegal_bins same_cycle = {0}; bins next = {1}; bins short = {[2:3]}; bins long = {[4:$]}; }
      cp_wait: coverpoint b_wait { bins none = {0}; bins some = {[1:$]}; }
      x_port_latency: cross cp_port, cp_latency;
    endgroup
    covergroup cg_events;
      option.per_instance = 1;
      cp_load_use: coverpoint ev.load_use { bins hit = {1}; }
      cp_redirect: coverpoint ev.redirect { bins hit = {1}; }
      cp_fetch_wait: coverpoint ev.fetch_wait { bins hit = {1}; }
      cp_arith_mem: coverpoint {ev.arith_wait, ev.mem_wait} { bins arith_only = {2'b10}; bins mem_only = {2'b01}; bins both = {2'b11}; }
      cp_retire_during_m: coverpoint {ev.arith_wait, ev.retired} { bins hit = {2'b11}; }
    endgroup
    function new(string name, uvm_component parent);
      super.new(name, parent);
      retire_imp = new("retire_imp", this); bus_imp = new("bus_imp", this); event_imp = new("event_imp", this);
      cg_retire = new(); cg_bus = new(); cg_events = new();
    endfunction
    function int distance(bit [4:0] r);
      if (r == 0 || last_write[r] == 0) return 0;
      return count - last_write[r] <= 3 ? int'(count - last_write[r]) : 0;
    endfunction
    function void write_retire(retire_item t);
      bit [31:0] in = t.rec.insn;
      if (t.is_reset) begin foreach (last_write[i]) last_write[i] = 0; return; end
      count++;
      f3 = in[14:12]; rd_zero = in[11:7] == 0; cause = t.rec.cause;
      uses_rs2 = in[6:0] inside {7'h33, 7'h3b, 7'h23, 7'h63};
      if (t.rec.trap) cls = C_TRAP;
      else case (in[6:0])
        7'h33: cls = in[31:25] == 1 ? C_M : C_ALU_R;
        7'h3b: cls = in[31:25] == 1 ? C_M_W : C_ALU_W;
        7'h13: cls = C_ALU_I;
        7'h1b: cls = C_ALU_IW;
        7'h37: cls = C_LUI;
        7'h17: cls = C_AUIPC;
        7'h6f: cls = C_JAL;
        7'h67: cls = C_JALR;
        7'h63: cls = t.rec.next_pc != t.rec.pc + 4 ? C_BR_TAKEN : C_BR_NOT;
        7'h03: cls = C_LOAD;
        7'h23: cls = C_STORE;
        7'h73: cls = C_SYS;
        default: cls = C_FENCE;
      endcase
      dist1 = distance(in[19:15]);
      dist2 = distance(in[24:20]);
      cg_retire.sample();
      if (!t.rec.trap && t.rec.rd != 0) last_write[t.rec.rd] = count;
    endfunction
    function void write_bus(bus_item t);
      b_fetch = t.fetch_port;
      if (t.phase == BUS_REQ) begin b_write = t.write; b_wait = t.waited; end
      else begin b_error = t.error; b_latency = t.waited; cg_bus.sample(); end
    endfunction
    function void write_event(event_item t); ev = t; cg_events.sample(); endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("COVERAGE", $sformatf("COVERAGE_SUMMARY retire=%0.2f bus=%0.2f events=%0.2f hazard_rs1=%0.2f hazard_rs2=%0.2f m_ops=%0.2f",
        cg_retire.get_inst_coverage(), cg_bus.get_inst_coverage(), cg_events.get_inst_coverage(),
        cg_retire.x_hazard_rs1.get_inst_coverage(), cg_retire.x_hazard_rs2.get_inst_coverage(),
        cg_retire.x_m_ops.get_inst_coverage()), UVM_NONE)
    endfunction
  endclass

  class transcript_writer extends uvm_component;
    `uvm_component_utils(transcript_writer)
    uvm_analysis_imp_fetch #(bus_item, transcript_writer) fetch_imp;
    uvm_analysis_imp_data #(bus_item, transcript_writer) data_imp;
    uvm_analysis_imp_retire #(retire_item, transcript_writer) retire_imp;
    int fd;
    bit started;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      fetch_imp = new("fetch_imp", this); data_imp = new("data_imp", this); retire_imp = new("retire_imp", this);
    endfunction
    function void open(string path);
      fd = $fopen(path, "w");
      if (fd == 0) `uvm_fatal("TRANSCRIPT", {"cannot open ", path})
      $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause");
      started = 0;
    endfunction
    function void close(); if (fd != 0) $fclose(fd); fd = 0; endfunction
    function void bus(bus_item t, string req_tag, string rsp_tag);
      if (fd == 0) return;
      if (t.phase == BUS_REQ) $fdisplay(fd, "%s,%016h,%01h,%02h,%016h", req_tag, t.addr, t.write, t.mask, t.wdata);
      else $fdisplay(fd, "%s,%01h,%016h", rsp_tag, t.error, t.rdata);
    endfunction
    function void write_fetch(bus_item t); bus(t, "IQ", "IR"); endfunction
    function void write_data(bus_item t); bus(t, "Q", "R"); endfunction
    function void write_retire(retire_item t);
      if (fd == 0) return;
      if (t.is_reset) begin
        if (started) $fdisplay(fd, "RESET");
        return;
      end
      started = 1;
      $fdisplay(fd, "%0d,%016h,%08h,%016h,%0d,%016h,%016h,%02h,%02h,%016h,%016h,%0d,%0d",
        t.rec.order, t.rec.pc, t.rec.insn, t.rec.next_pc, t.rec.rd, t.rec.rd_data, t.rec.mem_addr,
        t.rec.mem_rmask, t.rec.mem_wmask, t.rec.mem_rdata, t.rec.mem_wdata, t.rec.trap, t.rec.cause);
    endfunction
  endclass

  class cpu_env extends uvm_component;
    `uvm_component_utils(cpu_env)
    mem_agent fetch_agent, data_agent;
    retire_monitor retire_mon;
    cpu_scoreboard scoreboard;
    cpu_coverage coverage;
    transcript_writer transcript;
    mem_model mem;
    bit unified;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      virtual retire_if rvif;
      void'(uvm_config_db#(bit)::get(this, "", "unified", unified));
      mem = mem_model::type_id::create("env_mem");
      uvm_config_db#(mem_model)::set(this, "*_agent", "mem", mem);
      fetch_agent = mem_agent::type_id::create("fetch_agent", this);
      if (!unified) data_agent = mem_agent::type_id::create("data_agent", this);
      retire_mon = retire_monitor::type_id::create("retire_mon", this);
      scoreboard = cpu_scoreboard::type_id::create("scoreboard", this);
      coverage = cpu_coverage::type_id::create("coverage", this);
      transcript = transcript_writer::type_id::create("transcript", this);
      if (!uvm_config_db#(virtual retire_if)::get(this, "", "retire_vif", rvif)) `uvm_fatal("ENV", "no retire_vif")
      retire_mon.vif = rvif;
    endfunction
    function void connect_phase(uvm_phase phase);
      scoreboard.unified = unified;
      scoreboard.env_mem = mem;
      fetch_agent.monitor.ap.connect(scoreboard.fetch_imp);
      fetch_agent.monitor.ap.connect(coverage.bus_imp);
      fetch_agent.monitor.ap.connect(transcript.fetch_imp);
      if (!unified) begin
        data_agent.monitor.ap.connect(scoreboard.data_imp);
        data_agent.monitor.ap.connect(coverage.bus_imp);
        data_agent.monitor.ap.connect(transcript.data_imp);
      end
      retire_mon.ap.connect(scoreboard.retire_imp);
      retire_mon.ap.connect(coverage.retire_imp);
      retire_mon.ap.connect(transcript.retire_imp);
      retire_mon.events_ap.connect(coverage.event_imp);
    endfunction
  endclass

  typedef enum {I_ALU_R, I_ALU_I, I_ALU_W, I_ALU_IW, I_LUI, I_AUIPC, I_LOAD, I_STORE, I_BRANCH, I_JAL,
                I_M, I_FENCE, I_LOAD_USE, I_JALR, I_CSR} instr_kind_e;

  class instr_item extends uvm_sequence_item;
    `uvm_object_utils(instr_item)
    rand instr_kind_e kind;
    rand bit [4:0] rd, rs1, rs2;
    rand bit [2:0] f3;
    rand bit alt, word;
    rand bit [11:0] imm12;
    rand bit [5:0] shamt;
    rand bit [19:0] imm20;
    rand bit [2:0] slot;
    rand bit [1:0] skip;
    rand bit [1:0] filler;
    rand bit via_reg;
    rand bit [1:0] gap;
    constraint c_regs { rd inside {[0:7]}; rs1 inside {[0:7]}; rs2 inside {[0:7]};
                        rd dist {0 := 1, [1:7] := 14}; }
    constraint c_kind { kind dist {I_ALU_R := 14, I_ALU_I := 12, I_ALU_W := 6, I_ALU_IW := 5, I_LUI := 2, I_AUIPC := 2,
                                   I_LOAD := 10, I_STORE := 9, I_BRANCH := 10, I_JAL := 3, I_M := 10, I_FENCE := 1,
                                   I_LOAD_USE := 6, I_JALR := 2, I_CSR := 3}; }
    constraint c_skip { skip inside {[1:3]}; }
    bit allow_csr = 1;
    constraint c_csr { !allow_csr -> kind != I_CSR; }
    function new(string name = "instr_item"); super.new(name); endfunction
  endclass

  class program_sequencer extends uvm_sequencer #(instr_item);
    `uvm_component_utils(program_sequencer)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  class random_program_seq extends uvm_sequence #(instr_item);
    `uvm_object_utils(random_program_seq)
    rand int unsigned length;
    rand bit [63:0] seeds[7];
    bit allow_csr = 1;
    constraint c_length { length inside {[150:300]}; }
    function new(string name = "random_program_seq"); super.new(name); endfunction
    task body();
      repeat (length) begin
        instr_item item = instr_item::type_id::create("item");
        start_item(item);
        item.allow_csr = allow_csr;
        if (!item.randomize()) `uvm_fatal("SEQ", "instr_item randomize failed")
        finish_item(item);
      end
    endtask
  endclass

  class program_builder extends uvm_driver #(instr_item);
    `uvm_component_utils(program_builder)
    bit [31:0] words[$];
    int kind_hist[instr_kind_e];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    static function bit [31:0] r_type(bit [6:0] f7, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
      return {f7, rs2, rs1, f3, rd, op};
    endfunction
    static function bit [31:0] i_type(bit [11:0] imm, bit [4:0] rs1, bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
      return {imm, rs1, f3, rd, op};
    endfunction
    static function bit [31:0] s_type(bit [11:0] imm, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3);
      return {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23};
    endfunction
    static function bit [31:0] b_type(bit [12:0] off, bit [4:0] rs2, bit [4:0] rs1, bit [2:0] f3);
      return {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11], 7'h63};
    endfunction
    static function bit [31:0] j_type(bit [20:0] off, bit [4:0] rd);
      return {off[20], off[10:1], off[11], off[19:12], rd, 7'h6f};
    endfunction
    function void start_program(bit [63:0] seeds[7]);
      words.delete();
      words.push_back({20'h00004, 5'd20, 7'h17});
      for (int r = 1; r <= 7; r++) begin
        words.push_back(i_type(0, 0, 0, 5'(r), 7'h13));
        for (int i = 7; i >= 0; i--) begin
          words.push_back(i_type(12'd8, 5'(r), 1, 5'(r), 7'h13));
          words.push_back(i_type({4'b0, seeds[r-1][8*i +: 8]}, 5'(r), 0, 5'(r), 7'h13));
        end
      end
    endfunction
    function bit [4:0] base_of(instr_item t);
      return t.via_reg ? (t.rs1 == 0 ? 5'd1 : t.rs1) : 5'd20;
    endfunction
    function void base_reg(instr_item t);
      if (!t.via_reg) return;
      words.push_back(i_type(0, 5'd20, 0, base_of(t), 7'h13));
      repeat (t.gap) words.push_back(i_type(0, 0, 0, 0, 7'h13));
    endfunction
    function bit [31:0] filler_word(instr_item t);
      case (t.filler)
        0: return s_type({6'b0, t.slot, 3'b0}, t.rs2, 5'd20, 3);
        1: return r_type(7'h01, t.rs2, t.rs1, t.f3, t.rd, 7'h33);
        2: return i_type(12'd1, t.rs1, 0, t.rd, 7'h13);
        default: return r_type(0, t.rs2, t.rs1, 0, t.rd, 7'h33);
      endcase
    endfunction
    function void encode(instr_item t);
      bit [2:0] f3;
      int size;
      kind_hist[t.kind]++;
      case (t.kind)
        I_ALU_R: words.push_back(r_type(t.alt && (t.f3 == 0 || t.f3 == 5) ? 7'h20 : 7'h00, t.rs2, t.rs1, t.f3, t.rd, 7'h33));
        I_ALU_I: begin
          if (t.f3 == 1) words.push_back(i_type({6'b0, t.shamt}, t.rs1, 1, t.rd, 7'h13));
          else if (t.f3 == 5) words.push_back(i_type({t.alt ? 6'h10 : 6'h00, t.shamt}, t.rs1, 5, t.rd, 7'h13));
          else words.push_back(i_type(t.imm12, t.rs1, t.f3, t.rd, 7'h13));
        end
        I_ALU_W: begin
          f3 = t.f3 inside {0, 1, 5} ? t.f3 : 0;
          words.push_back(r_type(t.alt && f3 != 1 ? 7'h20 : 7'h00, t.rs2, t.rs1, f3, t.rd, 7'h3b));
        end
        I_ALU_IW: begin
          if (t.f3 == 1) words.push_back(i_type({7'b0, t.shamt[4:0]}, t.rs1, 1, t.rd, 7'h1b));
          else if (t.f3 == 5) words.push_back(i_type({t.alt ? 7'h20 : 7'h00, t.shamt[4:0]}, t.rs1, 5, t.rd, 7'h1b));
          else words.push_back(i_type(t.imm12, t.rs1, 0, t.rd, 7'h1b));
        end
        I_LUI: words.push_back({t.imm20, t.rd, 7'h37});
        I_AUIPC: words.push_back({t.imm20, t.rd, 7'h17});
        I_LOAD, I_LOAD_USE: begin
          f3 = t.f3 == 7 ? 3'd3 : t.f3;
          size = 1 << f3[1:0];
          base_reg(t);
          words.push_back(i_type(12'({t.slot, 3'b0} + (t.imm12[2:0] & 3'(8 - size))), base_of(t), f3, t.rd, 7'h03));
          if (t.kind == I_LOAD_USE) words.push_back(r_type(0, t.rd, t.rd, 0, t.rs2 == 0 ? 5'd1 : t.rs2, 7'h33));
        end
        I_STORE: begin
          f3 = {1'b0, t.f3[1:0]};
          size = 1 << f3[1:0];
          base_reg(t);
          words.push_back(s_type(12'({t.slot, 3'b0} + (t.imm12[2:0] & 3'(8 - size))), t.rs2, base_of(t), f3));
        end
        I_BRANCH: begin
          f3 = t.f3 inside {2, 3} ? 3'd0 : t.f3;
          words.push_back(b_type(13'(4 * (t.skip + 1)), t.rs2, t.rs1, f3));
          repeat (t.skip) words.push_back(filler_word(t));
        end
        I_JAL: begin
          words.push_back(j_type(21'(4 * (t.skip + 1)), t.rd));
          repeat (t.skip) words.push_back(filler_word(t));
        end
        I_M: begin
          f3 = t.word && t.f3 inside {1, 2, 3} ? 3'd0 : t.f3;
          words.push_back(r_type(7'h01, t.rs2, t.rs1, f3, t.rd, t.word ? 7'h3b : 7'h33));
        end
        I_FENCE: words.push_back(32'h0ff0000f);
        I_CSR: begin
          bit [11:0] csr_addr;
          case (t.slot[1:0]) 0: csr_addr = 12'h340; 1: csr_addr = 12'h342; 2: csr_addr = 12'h343; default: csr_addr = 12'hb02; endcase
          words.push_back({csr_addr, t.rs1, t.f3[2] ? 3'(4 + (t.f3[1:0] == 0 ? 1 : t.f3[1:0])) : 3'(t.f3[1:0] == 0 ? 1 : t.f3[1:0]), t.rd, 7'h73});
        end
        default: begin
          bit [4:0] base = t.rd == 0 ? 5'd1 : t.rd;
          words.push_back({20'h0, base, 7'h17});
          words.push_back(i_type(12'(16 + 4 * t.gap), base, 0, base, 7'h13));
          repeat (t.gap) words.push_back(i_type(0, 0, 0, 0, 7'h13));
          words.push_back(i_type(12'd0, base, 0, t.rs2, 7'h67));
          words.push_back(filler_word(t));
        end
      endcase
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        seq_item_port.get_next_item(req);
        encode(req);
        seq_item_port.item_done();
      end
    endtask
    function byte_array_t finish_program();
      byte_array_t image;
      words.push_back(32'h00100073);
      if (words.size() * 4 > 16'h4000) `uvm_fatal("BUILDER", "program overlaps data window")
      image = new[words.size() * 4];
      foreach (words[i]) for (int b = 0; b < 4; b++) image[4*i + b] = words[i][8*b +: 8];
      return image;
    endfunction
  endclass

  class cpu_base_test extends uvm_test;
    `uvm_component_utils(cpu_base_test)
    cpu_env env;
    virtual retire_if rvif;
    virtual bus_if ivif;
    int unsigned max_delay = 5;
    bit always_ready, unified;
    string out_dir = "uvm_out";
    int watchdog = 500000;
    function new(string name = "cpu_base_test", uvm_component parent = null); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mem_agent_cfg fcfg = mem_agent_cfg::type_id::create("fcfg");
      mem_agent_cfg dcfg = mem_agent_cfg::type_id::create("dcfg");
      if ($value$plusargs("MAX_DELAY=%d", max_delay)) begin end
      always_ready = $test$plusargs("ALWAYS_READY");
      if ($value$plusargs("OUT=%s", out_dir)) begin end
      void'(uvm_config_db#(bit)::get(this, "", "unified", unified));
      fcfg.fetch_port = !unified; fcfg.max_delay = max_delay; fcfg.always_ready = always_ready;
      dcfg.fetch_port = 0; dcfg.max_delay = max_delay; dcfg.always_ready = always_ready;
      uvm_config_db#(mem_agent_cfg)::set(this, "env.fetch_agent", "cfg", fcfg);
      uvm_config_db#(mem_agent_cfg)::set(this, "env.data_agent", "cfg", dcfg);
      env = cpu_env::type_id::create("env", this);
      if (!uvm_config_db#(virtual retire_if)::get(this, "", "retire_vif", rvif)) `uvm_fatal("TEST", "no retire_vif")
    endfunction
    task run_image(string name, byte_array_t image, int reset_after = -1);
      int cycles = 0;
      bit reset_done = 0;
      env.mem.load(image);
      env.scoreboard.load_program(image);
      env.transcript.open({out_dir, "/", name, ".csv"});
      write_hex({out_dir, "/", name, ".hex"}, image);
      cpu_uvm_ctrl::rst_request = 1;
      repeat (3) @(negedge rvif.clk);
      cpu_uvm_ctrl::rst_request = 0;
      while (!env.scoreboard.terminal) begin
        @(negedge rvif.clk);
        cycles++;
        if (cycles == reset_after && !reset_done) begin
          reset_done = 1;
          cpu_uvm_ctrl::rst_request = 1;
          repeat (3) @(negedge rvif.clk);
          cpu_uvm_ctrl::rst_request = 0;
        end
        if (cycles > watchdog) `uvm_fatal("TEST", {name, ": watchdog expired"})
      end
      repeat (20) @(negedge rvif.clk);
      for (int i = 0; i < 1000 && (env.scoreboard.fetch_out || env.scoreboard.data_out); i++) @(negedge rvif.clk);
      env.transcript.close();
      write_mem({out_dir, "/", name, ".csv.mem"});
      env.scoreboard.end_of_program(name);
    endtask
    function void write_hex(string path, byte_array_t image);
      int fd = $fopen(path, "w");
      $fdisplay(fd, "@00000000");
      foreach (image[i]) $fdisplay(fd, "%02h", image[i]);
      $fclose(fd);
    endfunction
    function void write_mem(string path);
      int fd = $fopen(path, "w");
      foreach (env.mem.data[i]) $fdisplay(fd, "%02h", env.mem.data[i]);
      $fclose(fd);
    endfunction
    function void report_phase(uvm_phase phase);
      uvm_report_server server = uvm_report_server::get_server();
      if (server.get_severity_count(UVM_ERROR) == 0 && server.get_severity_count(UVM_FATAL) == 0 && env.scoreboard.mismatches == 0)
        `uvm_info("TEST", "UVM_CPU_TEST_PASS", UVM_NONE)
    endfunction
  endclass

  class cpu_image_test extends cpu_base_test;
    `uvm_component_utils(cpu_image_test)
    function new(string name = "cpu_image_test", uvm_component parent = null); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      byte_array_t image;
      string path, name = "image";
      int reset_after = -1;
      phase.raise_objection(this);
      if (!$value$plusargs("IMAGE=%s", path)) `uvm_fatal("TEST", "IMAGE required")
      if ($value$plusargs("NAME=%s", name)) begin end
      if ($value$plusargs("RESET_AFTER=%d", reset_after)) begin end
      image = cpu_uvm_ctrl::read_image(path);
      run_image(name, image, reset_after);
      phase.drop_objection(this);
    endtask
  endclass

  class cpu_random_test extends cpu_base_test;
    `uvm_component_utils(cpu_random_test)
    program_sequencer sequencer;
    program_builder builder;
    int programs = 10;
    function new(string name = "cpu_random_test", uvm_component parent = null); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = program_sequencer::type_id::create("sequencer", this);
      builder = program_builder::type_id::create("builder", this);
      if ($value$plusargs("PROGRAMS=%d", programs)) begin end
    endfunction
    function void connect_phase(uvm_phase phase);
      builder.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      for (int p = 0; p < programs; p++) begin
        random_program_seq seq = random_program_seq::type_id::create("seq");
        int reset_after = -1;
        if (!seq.randomize()) `uvm_fatal("TEST", "sequence randomize failed")
        seq.allow_csr = !unified;
        builder.start_program(seq.seeds);
        seq.start(sequencer);
        if (p % 3 == 2) reset_after = 50 + p * 37;
        run_image($sformatf("random_%0d", p), builder.finish_program(), reset_after);
      end
      begin
        string hist = "";
        foreach (builder.kind_hist[k]) hist = {hist, $sformatf(" %s=%0d", k.name(), builder.kind_hist[k])};
        `uvm_info("TEST", {"STIMULUS_KINDS", hist}, UVM_NONE)
      end
      phase.drop_objection(this);
    endtask
  endclass
endpackage
