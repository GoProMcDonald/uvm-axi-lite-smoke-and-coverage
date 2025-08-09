interface axi_if(
  input logic clk, 
  input logic rst_n);
  // Write address channel
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;

  // Write data channel
  logic [31:0] wdata;
  logic  [3:0] wstrb;
  logic        wvalid;
  logic        wready;

  // Write response channel
  logic  [1:0] bresp;
  logic        bvalid;
  logic        bready;

  // Read address channel
  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;

  // Read data channel  
  logic [31:0] rdata;
  logic  [1:0] rresp;
  logic        rvalid;
  logic        rready;

  // 默认驱动任务（可选）
  task automatic drive_defaults();
    awaddr  <= '0; awvalid <= 0;
    wdata   <= '0; wstrb   <= 4'hF; wvalid <= 0;
    bready  <= 0;
    araddr  <= '0; arvalid <= 0;
    rready  <= 0;
  endtask

  //================================================
  // SystemVerilog Assertions (SVA)
  //================================================
  // 约定：
  // 1) VALID 必须保持到 READY 手握手完成。
  // 2) 地址在 VALID 高且未握手期间保持稳定。
  // 3) 写地址/写数握手后，有限拍内给出写响应。
  // 4) 读地址握手后，有限拍内给出读数据。

  // ---------- 辅助宏 ----------
  `define DISABLE_IF disable iff(!rst_n)// 断言在非复位状态下启用

  // 1) VALID 保持直到 READY
  property p_valid_stays_high(valid, ready);//定义一个可复用的时序属性（property）p_valid_stays_high，这里参数是 (valid, ready)。
    @(posedge clk) `DISABLE_IF (valid && !ready) |=> valid;// 在时钟上升沿，如果 valid 高且 ready 低，则在下一个时钟周期 valid 仍然高。`DISABLE_IF宏，等价于 disable iff(!rst_n)，意思是复位时不检查规则。
  endproperty


  // 2) VALID 期间地址稳定（以 AW 为例，同理 AR）
  property p_addr_stable(valid, ready, addr);
    @(posedge clk) `DISABLE_IF (valid && !ready) |=> $stable(addr);
  endproperty

  // 3) 写：AW+W 都握手后，N 拍内产生 BVALID
  // 这里用“写数据握手”触发时序；你也可在 env 中对齐 AW 与 W 的握手再触发。
  property p_write_resp_in_N;
    @(posedge clk) `DISABLE_IF (wvalid && wready) |-> ##[0:3] bvalid;
  endproperty

  // 4) 读：AR 握手后，N 拍内产生 RVALID
  property p_read_data_in_N;
    @(posedge clk) `DISABLE_IF (arvalid && arready) |-> ##[0:5] rvalid;
  endproperty

  // 5)（可选）AWVALID 拉高后“下个周期必须看到 AWREADY”——更严格版本
  // 若你的 DUT 允许多拍 back‑pressure，请改为 ##[0:K]
  property p_awready_next_cycle;
    @(posedge clk) `DISABLE_IF (awvalid && !awready) |-> ##1 awready;
  endproperty

  // ---------- 实例化断言 ----------
  // VALID 持续
  a_aw_valid_hold: assert property(p_valid_stays_high(awvalid, awready))//调用上面定义的 property p_valid_stays_high，并进行断言（检查）a_aw_valid_hold:给这个断言起个名字（方便报错时定位）。
    else $error("AWVALID dropped before AWREADY");//如果断言失败（条件不满足），执行 else 后面的动作，这里是 $error(...)
  a_w_valid_hold:  assert property(p_valid_stays_high(wvalid,  wready))
    else $error("WVALID dropped before WREADY");
  a_ar_valid_hold: assert property(p_valid_stays_high(arvalid, arready))
    else $error("ARVALID dropped before ARREADY");

  // 地址稳定
  a_aw_addr_stable: assert property(p_addr_stable(awvalid, awready, awaddr))
    else $error("AWADDR changed while waiting for AWREADY");
  a_ar_addr_stable: assert property(p_addr_stable(arvalid, arready, araddr))
    else $error("ARADDR changed while waiting for ARREADY");

  // 响应时限
  a_write_resp: assert property(p_write_resp_in_N)
    else $error("BVALID not seen within N cycles after W handshake");
  a_read_resp:  assert property(p_read_data_in_N)
    else $error("RVALID not seen within N cycles after AR handshake");

  // 严格 1 拍 AWREADY（按需启用）
  // a_awready_1cycle: assert property(p_awready_next_cycle)
  //   else $error("AWREADY not high next cycle after AWVALID");

  // ---------- cover property（示例）----------
  c_aw_hs: cover property(@(posedge clk) `DISABLE_IF (awvalid && awready));//cover property不是检查，而是统计“这个时序事件有没有发生过”。c_aw_hs:给这个覆盖事件起名字。
  c_w_hs:  cover property(@(posedge clk) `DISABLE_IF (wvalid  && wready));
  c_ar_hs: cover property(@(posedge clk) `DISABLE_IF (arvalid && arready));

endinterface
