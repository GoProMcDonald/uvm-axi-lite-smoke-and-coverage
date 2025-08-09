module dut_axi_lite_slave_regs(// AXI-Lite 从设备寄存器模块
  input  logic clk,
  input  logic rst_n,
  axi_if dif// AXI-Lite 接口实例
);
  // 很简单的寄存器文件：4个32位
  logic [31:0] regs[0:3];// 定义一个4个32位寄存器的数组

  // 简化：一直 ready（真实设计会有 backpressure）
  assign dif.awready = rst_n;
  assign dif.wready  = rst_n;
  assign dif.arready = rst_n;

  // 写通道：AW/W 同拍握手就写入；下拍给 BVALID
  logic write_fire_d;// 写事务触发标志，表示 AW/W 同拍握手完成
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin// 异步复位
      regs[0] <= 32'h0; regs[1] <= 32'h0; regs[2] <= 32'h0; regs[3] <= 32'h0;//进复位时清空 4 个寄存器
      dif.bvalid <= 1'b0;// BVALID 初始为 0
      dif.bresp  <= 2'b00;// BRESP 初始为 OKAY
      write_fire_d <= 1'b0;// 写事务触发标志，初始为 0。write_fire_d 是打一拍的“写握手完成”标志
    end else begin// 正常工作
      write_fire_d <= (dif.awvalid && dif.awready && dif.wvalid && dif.wready);// 如果 AW/W 同拍握手，就拉高 write_fire_d
      if (dif.awvalid && dif.awready && dif.wvalid && dif.wready) begin// 如果 AW/W 同拍握手，就写入寄存器
        regs[dif.awaddr[3:2]] <= dif.wdata;// 根据 AWADDR 的低两位选择寄存器写入 WDATA
      end
      // BVALID 拉一拍
      if (write_fire_d)// 如果 write_fire_d 被拉高，表示写事务完成
        dif.bvalid <= 1'b1;// 下拍给 BVALID
      else if (dif.bvalid && dif.bready) dif.bvalid <= 1'b0;// 如果 BVALID 已经拉高且 BREADY 也拉高了，就清除 BVALID
    end
  end

  // 读通道：AR握手后，下拍给 RVALID 和数据
  logic [31:0] rdata_q;
  logic        ar_fire_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_q   <= 32'h0;
      dif.rvalid <= 1'b0;
      dif.rresp  <= 2'b00;
      ar_fire_d <= 1'b0;
    end else begin
      ar_fire_d <= (dif.arvalid && dif.arready);// 如果 AR 握手完成，就拉高 ar_fire_d
      if (dif.arvalid && dif.arready) begin// 如果 AR 握手完成
        rdata_q <= regs[dif.araddr[3:2]];// 根据 ARADDR 的低两位选择寄存器读取数据
      end
      if (ar_fire_d) begin// 如果 ar_fire_d 被拉高，表示读事务完成
        dif.rvalid <= 1'b1;// 下拍给 RVALID
      end else if (dif.rvalid && dif.rready) begin
        dif.rvalid <= 1'b0;
      end
    end
  end

  assign dif.rdata = rdata_q;// 将读取的数据赋值给 RDATA 信号

endmodule
