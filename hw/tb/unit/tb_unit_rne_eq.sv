// =====================================================================
//  tb_unit_rne_eq.sv —— 常量移位宏 ATTN_RNE_SHR 与函数 attn_rne_shift 的逐位等价
//
//  ── 为什么需要这个测试 ──────────────────────────────────────────────
//  attn_math.svh 里现在有两套 RNE 右移实现：
//     attn_rne_shift(x, sh)   移位量可变（exp2 的 2^(-n)、fp16_quant 的对齐）
//     `ATTN_RNE_SHR(x, K)     移位量是编译期常量（顶层三处 + exp2 两处）
//  后者是为了让综合器把「减法求余 + 比较」换成「保护位/粘滞位」而写的，
//  它必须和前者的语义完全一致 —— 否则 RTL 与 C 模型的逐位一致就断了，
//  而这种断裂在系统级只看得到"某几个元素错一位"，极难回溯到移位宏。
//
//  这里对设计里用到的四个常量（16 / 12 / 24 / 10）做 40 万组比对，
//  含正负边界、恰好一半（tie）、最大最小 64 位整数。
//
//  ── 编译方式 ────────────────────────────────────────────────────────
//  跟着 flow/sim/unit.sh 走（ONLY=rne_eq make unit）。attn_math.svh 在那里
//  是**作为设计文件**进编译的，函数与宏都在本编译单元可见，不要再 include：
//  重复 include 会被 `ifndef ATTN_MATH_SVH 守卫挡掉，反而取不到定义。
// =====================================================================
`timescale 1ns/1ps

module tb_unit_rne_eq;

  int err = 0, ok = 0;

  // 把 K 送进宏：K 必须是字面量，不能是变量，所以只能逐值展开
  function automatic logic signed [63:0] new_f(input logic signed [63:0] x,
                                               input int                k);
    case (k)
      16:      new_f = `ATTN_RNE_SHR(x, 16);
      12:      new_f = `ATTN_RNE_SHR(x, 12);
      24:      new_f = `ATTN_RNE_SHR(x, 24);
      10:      new_f = `ATTN_RNE_SHR(x, 10);
      default: new_f = attn_rne_shift(x, k);   // 本测试不覆盖的 K 退回原函数
    endcase
  endfunction

  task automatic chk(input logic signed [63:0] x, input int k);
    logic signed [63:0] a, b;
    a = attn_rne_shift(x, k);
    b = new_f(x, k);
    if (a !== b) begin
      err++;
      if (err <= 12)
        $display("[UNIT] ✗ x=%0d (0x%016h) k=%0d  func=%0d  macro=%0d", x, x, k, a, b);
    end else ok++;
  endtask

  int ks [0:3];

  initial begin
    ks[0] = 16; ks[1] = 12; ks[2] = 24; ks[3] = 10;   // SH_Y@ref / SH_S@ref,FB / SH_P / SH_Y@10bit

    $display("[UNIT] name=rne_eq 比较 attn_rne_shift vs ATTN_RNE_SHR，K=16/12/24/10");

    // ---- 1. 定向：边界、tie、极值 ----
    foreach (ks[i]) begin
      int k;
      k = ks[i];
      chk(64'sd0,  k);
      chk(64'sd1,  k);
      chk(-64'sd1, k);
      chk(64'sd2,  k);
      chk(-64'sd2, k);
      chk(64'sh7FFF_FFFF_FFFF_FFFF, k);
      chk(-64'sh8000_0000_0000_0000, k);
      for (int d = -2; d <= 2; d++) begin
        chk( (64'sd1 <<  (k-1)) + d, k);                    // 正数 tie ± 2
        chk(-(64'sd1 <<  (k-1)) + d, k);                    // 负数 tie ± 2
        chk( (64'sd1 <<  (k-1)) + (64'sd1 << k) + d, k);
        chk(-(64'sd1 <<  (k-1)) - (64'sd1 << k) + d, k);
      end
      chk( (64'sd1 << k) - 64'sd1, k);                      // 余数全 1
      chk(-(64'sd1 << k) + 64'sd1, k);
      chk(-(64'sd1 << k), k);                               // 余数全 0
    end

    // ---- 2. 随机满 64 位（一半是负数，专打符号扩展）----
    for (int i = 0; i < 50000; i++) begin
      logic signed [63:0] x;
      x = {$random, $random};
      foreach (ks[j]) chk(x, ks[j]);
    end

    // ---- 3. 小范围随机（贴着实测数据落点）----
    for (int i = 0; i < 50000; i++) begin
      logic signed [63:0] x;
      x = $random % 200000;
      foreach (ks[j]) chk(x, ks[j]);
    end

    $display("[UNIT] name=rne_eq checked=%0d fail=%0d", ok, err);
    $display("[SUMMARY] name=rne_eq checked=%0d fail=%0d status=%0s",
             ok, err, (err == 0) ? "PASS" : "FAIL");
    if (err != 0) $display("[UNIT] ✗ 宏与原函数不等价：%0d 组不一致", err);
    $finish;
  end

endmodule
