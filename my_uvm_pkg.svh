//tb_top (SystemVerilog 顶层模块)
   //|
   //|-- run_test("axi_smoke_test")   // 告诉 UVM：我要跑哪个 test 类
   //       |
   //       v
   //axi_smoke_test::build_phase()    // 创建 env（里面有 agent、scoreboard）
   //axi_smoke_test::run_phase()      // 创建并 start smoke_sequence
   //       |
   //       v
   //env.agent.sqr <--- seq           // sequencer 驱动 driver
   //       |
   //       v
   //driver 发激励 → DUT
   //monitor 采集总线事务 → scoreboard 检查


`ifndef MY_UVM_PKG_SVH//头文件保护（header guard）如果没有这个保护，你的 axi_seq_item、axi_driver 这些类可能会被编译两遍，直接报错。
`define MY_UVM_PKG_SVH//那么现在定义它

`include "uvm_macros.svh"//把 UVM 的宏定义文件引进来。里面有我们常用的\uvm_component_utils(...)、`uvm_object_utils(...)、`uvm_info/.../error/fatal` 等宏。

package my_uvm_pkg;//定义一个包，所有后面的类型、类、typedef 都放在这个命名空间里，方便在别的文件里一句 import my_uvm_pkg::*; 全部引入
  import uvm_pkg::*;// 引入 UVM 包，包含了 UVM 的所有类和宏定义
  `uvm_analysis_imp_decl(_exp)
  `uvm_analysis_imp_decl(_act)
  // --------------------- Transaction ---------------------
  class axi_seq_item extends uvm_sequence_item;

  `uvm_object_utils(axi_seq_item)

  // 明确区分读写与数据方向，便于 driver/monitor/scoreboard 使用
  rand bit          is_write;       // 1=写，0=读（旧字段 write 可用函数别名兼容）
  rand logic [31:0] addr;           // 寄存器地址/偏移
  rand logic [31:0] wdata;          // 仅在写事务时有效
       logic [31:0] rdata;          // 仅在读事务完成后有效
       bit   [1:0]  resp;           // AXI-lite 响应：bresp/rresp

  function new(string name="axi_seq_item");
    super.new(name);
  endfunction

  // 可选：兼容你之前使用 write 的旧代码
  function bit write(); return is_write; endfunction

  // 便于日志打印
  virtual function void do_print(uvm_printer printer);
    super.do_print(printer);
    printer.print_field_int("is_write", is_write, 1, UVM_DEC);
    printer.print_field_int("addr"    , addr    , 32, UVM_HEX);
    printer.print_field_int("wdata"   , wdata   , 32, UVM_HEX);
    printer.print_field_int("rdata"   , rdata   , 32, UVM_HEX);
    printer.print_field_int("resp"    , resp    ,  2, UVM_BIN);
  endfunction
endclass

  // --------------------- Sequencer -----------------------
  typedef uvm_sequencer #(axi_seq_item) axi_sequencer;//给带参数的 sequencer起个别名。等价于“一个只处理 axi_seq_item 的 sequencer”。

  // --------------------- Driver --------------------------这个 driver 是 UVM 骨架中唯一会主动去驱动 DUT 信号的模块，它负责把上层 sequence 发来的抽象事务（addr/data/类型）翻译成符合 AXI-Lite 协议的 valid/ready 握手时序，并在正确时机拉高/拉低各个信号。
  class axi_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(axi_driver)//把这个组件注册进 UVM 工厂。以后用 ::type_id::create("drv", parent) 才能创建它
    virtual axi_if vif;//虚接口句柄。driver 通过它给 DUT 施加引脚电平。

     uvm_analysis_port #(axi_seq_item) exp_ap; // 定义一个分析端口 exp_ap，用于接收来自 sequencer 的事务意图（exp）

    function new(string name, uvm_component parent); 
        super.new(name,parent); 
        exp_ap = new("exp_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF","axi_driver: no vif")
    endfunction

    task run_phase(uvm_phase phase);//驱动时序都写在 run 阶段
      // 初始默认
      //@(negedge vif.rst_n);//等一次复位拉低再等复位释放。保证 driver 在“复位完成后”才开始对 DUT 说话。
      @(posedge vif.rst_n);// 等复位释放
      vif.drive_defaults();//调接口里的默认驱动任务，把所有 valid/addr/data 等清零，避免上电即乱驱动。
      forever begin//循环处理事务
        axi_seq_item tr;//定义一个事务变量tr，类型是axi_seq_item
        seq_item_port.get_next_item(tr);//从sequencer拉取下一个事务，阻塞直到有新事务
        exp_ap.write(tr);//把事务克隆一份，发给分析端口 exp_ap（如果有订阅者的话）。这一步是可选的，主要用于调试和验证。
        if (tr.is_write) drive_write(tr);//如果是写事务，调用 drive_write 子任务
        else          drive_read(tr);// 如果是读事务，调用 drive_read 子任务
        seq_item_port.item_done();//通知sequencer，这个事务已处理完毕，可以发下一个
      end
    endtask

    task automatic drive_write(axi_seq_item tr);
      // 地址/数据/握手
      @(posedge vif.clk);
      vif.awaddr  <= tr.addr;
      vif.awvalid <= 1;
      vif.wdata   <= tr.wdata;
      vif.wstrb   <= 4'hF;
      vif.wvalid  <= 1;
      vif.bready  <= 1;

      // 等待 AW & W 握手
      wait(vif.awvalid && vif.awready);
      wait(vif.wvalid  && vif.wready);

      // 拉低 valid
      @(posedge vif.clk);
      vif.awvalid <= 0;
      vif.wvalid  <= 0;

      // 等待 BVALID -> BREADY
      wait(vif.bvalid);
      @(posedge vif.clk);
      vif.bready  <= 0;
    endtask

    task automatic drive_read(axi_seq_item tr);
      @(posedge vif.clk);
      vif.araddr  <= tr.addr;
      vif.arvalid <= 1;
      vif.rready  <= 1;

      // 等待 AR 握手
      wait(vif.arvalid && vif.arready);
      @(posedge vif.clk);
      vif.arvalid <= 0;

      // 等待 R 有效（数据由 monitor 捕获）
      wait(vif.rvalid);
      @(posedge vif.clk);
      vif.rready <= 0;
    endtask
  endclass

  // --------------------- Covergroup ---------------------------
  class axi_coverage extends uvm_object;
  `uvm_object_utils(axi_coverage)

  //盖采样变量
  bit        tr_cmd;
  bit [31:0] tr_addr;
  bit [31:0] tr_wdata;

  covergroup axi_cg;// 定义一个 covergroup，名为 axi_cg
    option.per_instance = 1;// 每个实例单独采样
    // 命令类型覆盖
    coverpoint tr_cmd {
      bins read  = {0};//tr_cmd值等于 0 时命中 read 桶
      bins write = {1};//tr_cmd值等于 1 时命中 write 桶
    }
        // 地址区间覆盖
    coverpoint tr_addr[7:0] {
      bins low  = {[8'h00:8'h0F]};//地址低8位在 0x00 ~ 0x0F命中low 桶
      bins mid  = {[8'h10:8'h7F]};//地址低8位在 0x10 ~ 0x7F命中 mid 桶
      bins high = {[8'h80:8'hFF]};//地址低8位在 0x80 ~ 0xFF命中 high 桶
    }
    // 写数据覆盖
    coverpoint tr_wdata[7:0] iff (tr_cmd == 1) {//对写数据低 8 位 tr_wdata[7:0]（且 tr_cmd==1 才统计）：
      bins zero  = {8'h00};//tr_wdata[7:0] 等于 0x00 时命中 zero 桶
      bins small_range = {[8'h01:8'h3F]};// tr_wdata[7:0] 在 0x01 ~ 0x3F 时命中 small_range 桶
      bins big   = {[8'h40:8'hBF]};// tr_wdata[7:0] 在 0x40 ~ 0xBF 时命中 big 桶
      bins large_range = {[8'hC0:8'hFF]};// tr_wdata[7:0] 在 0xC0 ~ 0xFF 时命中 large_range 桶
    }
    // 交叉覆盖
    cross tr_cmd, tr_addr;//交叉覆盖命令类型与地址
  endgroup

  function new(string name="axi_coverage");
    super.new(name);
    axi_cg = new();// 实例化 covergroup
  endfunction

  // 采样方法
  function void sample(bit cmd, bit [31:0] addr, bit [31:0] wdata);
    this.tr_cmd   = cmd;
    this.tr_addr  = addr;
    this.tr_wdata = wdata;
    axi_cg.sample();// 调用 covergroup 的 sample 方法进行采样
  endfunction
endclass 

  // --------------------- Monitor -------------------------
  class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)
  import my_uvm_pkg::*;

  // ===== 接口与端口 =====
  virtual axi_if vif;
  uvm_analysis_port #(axi_seq_item) ap;

  // ===== 覆盖率辅助量 =====
  // 0 = READ, 1 = WRITE
  bit cmd_type_q;

  // ===== 覆盖率定义 =====
  // 只在有效握手时采样；并把 bins 名字避开 small/large 等保留词
  covergroup cg_axi with function sample(
    bit               is_wr,
    logic [31:0]      aw,
    byte              wd,     // 8 位就够统计范围；若要更宽可改
    logic [31:0]      ar
    );
    option.per_instance = 1;

    // 写地址区间
    cp_awaddr : coverpoint aw iff (is_wr) {
    bins aw_lo   = {[32'h0000_0000 : 32'h0000_00FF]}; // 低地址
    bins aw_mid  = {[32'h0000_0100 : 32'h0000_0FFF]}; // 中地址
    bins aw_high = default;                            // 其他都算高
  }

    // 写数据区间（示例 8 位 bins；若 wdata 更宽可自行调整区间）
    cp_wdata : coverpoint wd iff (is_wr) {
    bins d_small_range  = {[8'h01 : 8'h3F]};
    bins d_medium_range = {[8'h40 : 8'hBF]};
    bins d_large_range  = {[8'hC0 : 8'hFF]};
  }

    // 读地址区间
    cp_araddr : coverpoint ar iff (!is_wr) {
    bins ar_lo   = {[32'h0000_0000 : 32'h0000_00FF]};
    bins ar_mid  = {[32'h0000_0100 : 32'h0000_0FFF]};
    bins ar_high = default;
  }

    // 命令类型：0=读 1=写
    cp_cmd : coverpoint is_wr {
    bins READ  = {0};
    bins WRITE = {1};
  }

    // 交叉覆盖
    x_wr_addr_data : cross cp_awaddr, cp_wdata; // 写地址 × 写数据
    x_cmd_raddr    : cross cp_cmd, cp_araddr;   // 命令类型 × 读地址
  endgroup : cg_axi

  // ===== 构造/阶段函数 =====
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
    cg_axi = new(); // 实例化 covergroup
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("NOVIF", "axi_monitor: no virtual interface set for 'vif'")
    end
  endfunction

  // 根据你的项目需要，这里也可以构造并发送 axi_seq_item
  task run_phase(uvm_phase phase);
    super.run_phase(phase);

    forever begin
      @(posedge vif.clk);

      // ---- 写事务握手采样：AW & W 同拍或相邻拍都可
      if ((vif.awvalid && vif.awready) &&
          (vif.wvalid  && vif.wready)) begin
        axi_seq_item tr_w;
        cg_axi.sample(1'b1, vif.awaddr, vif.wdata[7:0], 32'h0);

        // （可选）往外送事务
     
        tr_w = axi_seq_item::type_id::create("tr_w", this);
        tr_w.is_write = 1;           // 依据你的定义
        tr_w.addr   = vif.awaddr;
        tr_w.wdata  = vif.wdata;
        ap.write(tr_w);
      end

      // ---- 读事务握手采样：AR
      if (vif.arvalid && vif.arready) begin
        axi_seq_item tr_r;
        logic [31:0] araddr_latched;   // 锁存读地址
        cg_axi.sample(1'b0, 32'h0, 8'h0, vif.araddr);
        // 1) 锁存 AR 地址（因为后面可能变化）
        araddr_latched = vif.araddr;
          // 2) 等待数据返回握手
        @(posedge vif.clk);
        wait (vif.rvalid && vif.rready);
        // （可选）往外送事务（读地址阶段）
        tr_r = axi_seq_item::type_id::create("tr_r", this);
        tr_r.is_write = 0;
        tr_r.addr     = araddr_latched;
        tr_r.rdata    = vif.rdata;  
        ap.write(tr_r);
      end
    end
  endtask

  // 收尾打印本实例覆盖率
  function void report_phase(uvm_phase phase);
    real cov = cg_axi.get_inst_coverage();
    `uvm_info("COV", $sformatf("Functional coverage (axi_monitor) = %0.2f%%", cov),
              UVM_LOW)
  endfunction

endclass

  // --------------------- Agent ---------------------------
  class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)
    axi_driver    drv;
    axi_sequencer sqr;
    axi_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name,parent);
    endfunction

    function void build_phase(uvm_phase phase);//在 build 阶段，用工厂方法 ::type_id::create() 创建出 driver、sequencer、monitor 三个组件，并且把它们挂在当前 agent 下面（this 是 parent）
      super.build_phase(phase);
      drv = axi_driver   ::type_id::create("drv", this);// 创建 driver的实例
      sqr = axi_sequencer::type_id::create("sqr", this);// 创建 sequencer 的实例
      mon = axi_monitor  ::type_id::create("mon", this);//  创建 monitor 的实例
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      drv.seq_item_port.connect(sqr.seq_item_export);//连接 driver 的 seq_item_port 到 sequencer 的 seq_item_export，这样 driver 就能从 sequencer 拉取事务了。
    endfunction
  endclass

  // --------------------- Scoreboard -----------------------------
  class axi_scoreboard extends uvm_scoreboard;//定义一个名为 axi_scoreboard 的 UVM 组件，类型是 scoreboard
  `uvm_component_utils(axi_scoreboard)//把该类注册到 UVM 工厂，以后可以用 ::type_id::create("scb", parent) 创建它。

  uvm_analysis_imp_exp #(axi_seq_item, axi_scoreboard) exp_imp; //一个 analysis_imp 终端，接收 driver 发来的“期望/意图”事务（exp）
  uvm_analysis_imp_act #(axi_seq_item, axi_scoreboard) act_imp; //一个 analysis_imp 终端，接收 monitor 发来的“实际/采样”事务（act）

  bit [31:0] ref_mem [bit [31:0]];// 影子模型：用来存储写入的地址和数据。类似于一个笔记本，记录每个地址的写入数据。
  typedef struct packed { bit [31:0] addr; } read_req_t;// 定义一个结构体 read_req_t，包含一个 32 位的地址字段，用于存储读请求的地址。
  read_req_t pending_reads[$];// 定义一个动态数组 pending_reads，用于存储所有未处理的读请求。

  int unsigned num_read_checked;// 统计已检查的读请求数量
  int unsigned num_write_tracked;// 统计已跟踪的写请求数量
  int unsigned num_mismatch;// 统计不匹配的读请求数量

  function new(string name, uvm_component parent);// 构造函数，创建一个 axi_scoreboard 实例
    super.new(name, parent);
    exp_imp = new("exp_imp", this);// 创建一个名为 exp_imp 的 analysis_imp 实例，用于接收期望事务
    act_imp = new("act_imp", this);// 创建一个名为 act_imp 的 analysis_imp 实例，用于接收实际事务
  endfunction

  function void write_exp(axi_seq_item tr);// 接收意图（来自 driver）。处理期望事务（来自 driver）当 driver 的 exp_ap.write(tr) 触发，且连接了 driver.exp_ap → scoreboard.exp_imp，UVM 自动回调到这里。
    if (tr.is_write) begin// 如果是写事务，把“将要写入的数据”写入影子模型 ref_mem，同时写计数 + 打印日志
      ref_mem[tr.addr] = tr.wdata;// 更新影子模型
      num_write_tracked++;// 增加写计数
      `uvm_info("SCB/EXP", $sformatf("WRITE intent: addr=0x%08h data=0x%08h", tr.addr, tr.wdata), UVM_LOW)// 打印写意图信息
    end
    else begin// 如果是读事务，记录这个地址的读请求到 pending_reads 数组中，把读地址排入 pending_reads 队列，等待稍后 monitor 的实际读回来时进行配对比对。
      read_req_t req; req.addr = tr.addr;// 创建一个读请求结构体，设置地址
      pending_reads.push_back(req);// 将读请求添加到 pending_reads 队列
      `uvm_info("SCB/EXP", $sformatf("READ intent:  addr=0x%08h (queued)", tr.addr), UVM_LOW)
    end
  endfunction

  function void write_act(axi_seq_item tr);//接收实际（来自 monitor）。处理实际事务（来自 monitor）当 monitor 的 ap.write(tr) 触发，且连接了 monitor.ap → scoreboard.act_imp，UVM 自动回调到这里。
    read_req_t req;
    logic [31:0]  exp_data;
    if (!tr.is_write) begin//这里只处理读实际（!tr.cmd），写实际可按需扩展
      if (pending_reads.size() == 0) begin//若没有任何排队的读意图，却来了一个读实际 → 说明时序/配对乱了（或某些读意图丢了），直接记一次不匹配并报错。
        num_mismatch++;// 增加不匹配计数
        `uvm_error("SCB/ACT", $sformatf("Actual READ with no pending intent! addr=0x%08h rdata=0x%08h", tr.addr, tr.rdata))// 打印错误信息
        return;
      end

      req = pending_reads.pop_front();
      if (req.addr != tr.addr) begin// 如果读请求的地址和实际事务的地址不匹配，说明时序乱了或意图丢失
        num_mismatch++;// 增加不匹配计数
        `uvm_error("SCB/ADDR", $sformatf("READ addr mismatch! exp=0x%08h act=0x%08h", req.addr, tr.addr))// 打印地址不匹配错误
        return;
      end

      exp_data = ref_mem.exists(tr.addr) ? ref_mem[tr.addr] : '0;// 从影子模型中获取期望数据，如果地址未写入过，则默认为0
      if (tr.rdata !== exp_data) begin// 如果实际读回的数据和期望数据不匹配，记录不匹配并报错
        num_mismatch++;// 增加不匹配计数
        `uvm_error("SCB/MISMATCH", $sformatf("READ data mismatch @0x%08h: EXP=0x%08h ACT=0x%08h", tr.addr, exp_data, tr.rdata))// 打印数据不匹配错误
      end
      else begin// 如果实际读回的数据和期望数据匹配，打印匹配信息
        num_read_checked++;// 增加已检查的读请求计数
        `uvm_info("SCB/MATCH", $sformatf("READ match @0x%08h: data=0x%08h", tr.addr, tr.rdata), UVM_LOW)// 打印读匹配信息
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);// 在报告阶段打印统计信息
    `uvm_info("SCB/REPORT", $sformatf(
      "Summary: write_intents=%0d, read_checked=%0d, mismatches=%0d, pending_reads=%0d",
      num_write_tracked, num_read_checked, num_mismatch, pending_reads.size()), UVM_NONE)// 打印统计信息
    if (num_mismatch == 0) `uvm_info("SCB/REPORT", "All checks passed ✅", UVM_NONE)// 如果没有不匹配，打印通过信息
    else `uvm_error("SCB/REPORT", "Some checks failed ❌")// 如果有不匹配，打印失败信息
  endfunction
endclass

  // --------------------- Env -----------------------------
  class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)
    axi_agent      agent;// 定义一个 axi_agent 类型的变量 agent，用于创建和管理 AXI-Lite 代理
    axi_scoreboard sb;// 定义一个 axi_scoreboard 类型的变量 sb，用于验证 AXI-Lite 事务

    function new(string name, uvm_component parent);
        super.new(name,parent); 
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = axi_agent     ::type_id::create("agent", this);// 创建一个 axi_agent 实例
      sb    = axi_scoreboard::type_id::create("sb",    this);// 创建一个 axi_scoreboard 实例
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.drv.exp_ap.connect(sb.exp_imp); // driver → scoreboard（意图exp）
      agent.mon.ap   .connect(sb.act_imp);  // monitor → scoreboard（实际act）
    endfunction

  endclass

  // --------------------- Smoke Sequence ------------------
  class axi_smoke_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_smoke_seq)
    function new(string name="axi_smoke_seq"); super.new(name); endfunction
    task body();
      axi_seq_item tr;

      // wr 0x0 = A5A5_0001
      tr = axi_seq_item::type_id::create("wr0");
      start_item(tr); tr.is_write=1; tr.addr='h0; tr.wdata='hA5A5_0001; finish_item(tr);

      // rd 0x0
      tr = axi_seq_item::type_id::create("rd0");
      start_item(tr); tr.is_write=0; tr.addr='h0;                         finish_item(tr);

      // wr 0x4 = DEAD_BEEF
      tr = axi_seq_item::type_id::create("wr1");
      start_item(tr); tr.is_write=1; tr.addr='h4; tr.wdata='hDEAD_BEEF;    finish_item(tr);

      // rd 0x4
      tr = axi_seq_item::type_id::create("rd1");
      start_item(tr); tr.is_write=0; tr.addr='h4;                         finish_item(tr);
    endtask
  endclass

  // --------------------- Coverage Sequence ------------------
  class axi_cov_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_cov_seq)
  function new(string name="axi_cov_seq");
    super.new(name);
  endfunction

  // ——助手任务：对一组地址把 small/medium/large 都打齐，并各自读回
  task automatic hit_all_wdata_for_addrs(logic [31:0] A[]);//定义一个子任务，接收一个动态数组 A[]，元素类型是 logic [31:0]（地址列表）
    axi_seq_item tr;// 定义一个事务变量 tr，类型是 axi_seq_item
    byte wvals_small[]  = '{8'h01, 8'h20, 8'h3F};// 定义一个小范围的写数据数组，包含 8 位小值
    byte wvals_medium[] = '{8'h40, 8'h90, 8'hBF};// 定义一个中范围的写数据数组，包含 8 位中值
    byte wvals_large[]  = '{8'hC0, 8'hF0, 8'hFF};// 定义一个大范围的写数据数组，包含 8 位大值

    foreach (A[i]) begin//foreach 遍历动态数组 A 的所有索引 i
      foreach (wvals_small[j]) begin//对每个地址 A[i]，再对每个 small 值 wvals_small[j] 做写→读。
        tr = axi_seq_item::type_id::create($sformatf("wr_s_%0d_%0d", i, j)); start_item(tr);// 创建一个写事务，名字格式为 wr_s_i_j
        tr.is_write=1; tr.addr=A[i]; tr.wdata={24'h0, wvals_small[j]}; finish_item(tr);

        tr = axi_seq_item::type_id::create($sformatf("rd_s_%0d_%0d", i, j)); start_item(tr);// 创建一个读事务，名字格式为 rd_s_i_j
        tr.is_write=0; tr.addr=A[i]; finish_item(tr);
      end
      foreach (wvals_medium[j]) begin
        tr = axi_seq_item::type_id::create($sformatf("wr_m_%0d_%0d", i, j)); start_item(tr);
        tr.is_write=1; tr.addr=A[i]; tr.wdata={24'h0, wvals_medium[j]}; finish_item(tr);

        tr = axi_seq_item::type_id::create($sformatf("rd_m_%0d_%0d", i, j)); start_item(tr);
        tr.is_write=0; tr.addr=A[i]; finish_item(tr);
      end
      foreach (wvals_large[j]) begin
        tr = axi_seq_item::type_id::create($sformatf("wr_l_%0d_%0d", i, j)); start_item(tr);
        tr.is_write=1; tr.addr=A[i]; tr.wdata={24'h0, wvals_large[j]}; finish_item(tr);

        tr = axi_seq_item::type_id::create($sformatf("rd_l_%0d_%0d", i, j)); start_item(tr);
        tr.is_write=0; tr.addr=A[i]; finish_item(tr);
      end
    end
  endtask

  // ——主任务
    task body();
    // 三个地址区间各取代表值（与你 covergroup 的 bins 对齐）
      logic [31:0] addrs_lo [] = '{32'h0000_0000, 32'h0000_0010, 32'h0000_007F};// 定义低地址区间的地址数组
      logic [31:0] addrs_mid[] = '{32'h0000_0100, 32'h0000_0200, 32'h0000_0FFF};// 定义中地址区间的地址数组
      logic [31:0] addrs_hi [] = '{32'h0001_0000, 32'h1000_0000, 32'hFFFF_FF00};// 定义高地址区间的地址数组

      hit_all_wdata_for_addrs(addrs_lo);// 对低地址区间的地址调用 hit_all_wdata_for_addrs
      hit_all_wdata_for_addrs(addrs_mid);// 对中地址区间的地址调用 hit_all_wdata_for_addrs
      hit_all_wdata_for_addrs(addrs_hi);// 对高地址区间的地址调用 hit_all_wdata_for_addrs
    endtask
  endclass
  
  // --------------------- Test ----------------------------
  class axi_smoke_test extends uvm_test;
    `uvm_component_utils(axi_smoke_test)
    axi_env env;
    axi_smoke_seq s;  // 只声明

    function new(string name="axi_smoke_test", uvm_component parent=null); 
        super.new(name,parent); 
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = axi_env::type_id::create("env", this);// 创建一个 axi_env 实例
    endfunction

    task run_phase(uvm_phase phase);
      axi_cov_seq s;
      phase.raise_objection(this);// 抬起一个异步阻塞，表示测试开始
      s = axi_cov_seq::type_id::create("s", this);
      s.start(env.agent.sqr);// 启动这个 sequence，传入 agent 的 sequencer，这样它就能发事务了。
      #50;
      phase.drop_objection(this);// 放下异步阻塞，表示测试结束
    endtask
  endclass

endpackage
`endif // MY_UVM_PKG_SVH
