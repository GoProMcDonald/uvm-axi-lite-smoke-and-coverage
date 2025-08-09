`timescale 1ns/1ps// 设置时间单位为1ns，精度为1ps。下面的 #5 就是 5ns
`include "uvm_macros.svh"//预处理“包含”UVM宏（uvm_info/uvm_error、_utils 等）
`include "my_uvm_pkg.svh"//把你自定义的 UVM 包文件也直接“贴进来”。一般里面定义了 env/agent/driver/seq 等 class。

module tb_top;//顶层 testbench 模块名
  import uvm_pkg::*;// 导入 UVM 包，包含了 UVM 的所有类和宏
  import my_uvm_pkg::*;// 导入你自定义的 UVM 包，包含了你的 env/agent/driver/seq 等类

  // 时钟复位
  logic clk; 
  logic rst_n;

  initial begin
    $dumpfile("dump.vcd");   // 指定VCD文件名（EPWave默认找这个）
    $dumpvars(0, tb_top);    // 把tb_top及其所有层级的信号都dump进去
  end
  
  initial begin
    clk = 0; forever #5 clk = ~clk; // 100MHz
  end

  initial begin
    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
  end

  // 接口 & DUT
  axi_if dif(.clk(clk), .rst_n(rst_n));//例化一个 接口实例 dif，把顶层 clk/rst_n连进去
  dut_axi_lite_slave_regs dut(
    .clk   (clk),
    .rst_n (rst_n),
    .dif   (dif)
  );

  // 将虚接口注入到UVM（driver/monitor会get）
  initial begin
    // 你也可以用更宽匹配："uvm_test_top.env.agent.*"
    uvm_config_db#(virtual axi_if)::set(null, "uvm_test_top.env.agent.*", "vif", dif);// 把虚接口 dif 设置到 UVM 的配置数据库中，这样 driver 和 monitor 就能通过 uvm_config_db 获取到它
    run_test("axi_smoke_test");// 启动 UVM 测试，运行名为 axi_smoke_test 的测试类
  end

endmodule
