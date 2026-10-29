// =====================================================================
//  tb_unit_fp16_quant.sv —— fp16_quant 穷举对拍
//
//  被测：FP16 位模式 → s(QB).QF（RNE + 饱和）
//  激励：**全部 65536 个位模式**，一个不漏。
//        这是唯一一个真的能穷举的模块（输入空间 16 位），
//        所以这里不该留任何随机采样。
//
//  ── 域的划分（这点要在报告里写明，否则"穷举"会被质疑）──────────────
//    legal    ：e != 31，共 63488 个。模型有定义，必须逐位一致。
//    special  ：e == 31（inf / ±NaN），共 2048 个。C 模型的 nearbyint(inf)
//               是未定义行为，模型侧根本没有对应值 —— 题面输入恒为有限值，
//               这一档只检查两件事：输出不是 X，且按符号饱和到端点。
//               不把它算进 PASS/FAIL 的分子分母，而是单独报数。
//
//  ── 判据 ────────────────────────────────────────────────────────────
//    期望值由 unit_ref_pkg::quant_ref() 按数学定义 rne(x*2^QF) + 饱和算出，
//    与 RTL 的"改移位量"实现是两条独立路径。
// =====================================================================
`timescale 1ns/1ps
module tb_unit_fp16_quant;
  import attn_pkg::*;
  import unit_ref_pkg::*;

  localparam int QB = Q_BITS;
  localparam int QF = Q_FRAC;

  logic [15:0]          x;
  logic signed [QB-1:0] q;

  fp16_quant dut (.x(x), .q(q));

  int     nlegal, nfail;
  int     nspecial, nfail_special;
  longint exp_v, got_v;

  initial begin
    nlegal = 0; nfail = 0; nspecial = 0; nfail_special = 0;

    $display("[UNIT] name=fp16_quant qb=%0d qf=%0d domain=65536", QB, QF);
    $display("[UNIT]   合法域 = %0d 个位模式（e!=31），异常域 = %0d（inf/nan）",
             (1 << 16) - 2 * (1 << 10), 2 * (1 << 10));

    for (int i = 0; i < (1 << 16); i++) begin
      x = 16'(i);
      #1;                                  // 等组合逻辑稳定
      got_v = longint'(q);

      if (x[14:10] == 5'h1F) begin
        // ---- 异常域：只要求无 X + 按符号饱和 ----
        nspecial++;
        exp_v = x[15] ? -(longint'(1) << (QB - 1))
                      :  ((longint'(1) << (QB - 1)) - 1);
        if ($isunknown(q) || got_v !== exp_v) begin
          nfail_special++;
          if (nfail_special <= 4)
            $display("[UNIT]   ✗ special x=%04h (e=31) got=%0d exp=%0d",
                     x, got_v, exp_v);
        end
      end else begin
        // ---- 合法域：逐位一致 ----
        nlegal++;
        exp_v = quant_ref(x, QB, QF);
        if (got_v !== exp_v) begin
          nfail++;
          if (nfail <= 8)
            $display("[UNIT]   ✗ x=%04h(%0.6f) got=%0d exp=%0d",
                     x, f16_to_r(x), got_v, exp_v);
        end
      end
    end

    // ---- 顺手抽查几个"必然饱和"的点，确认饱和边界没写偏 ----
    // 最大有限值 65504 * 2^QF 远超 QB 位范围，两个方向都必须贴到端点。
    x = 16'h7BFF; #1;                       // +65504
    $display("[UNIT]   饱和检查 +65504 → %0d（期望 %0d）", longint'(q),
             (longint'(1) << (QB - 1)) - 1);
    x = 16'hFBFF; #1;                       // -65504
    $display("[UNIT]   饱和检查 -65504 → %0d（期望 %0d）", longint'(q),
             -(longint'(1) << (QB - 1)));

    $display("[UNIT] name=fp16_quant legal=%0d fail=%0d special=%0d fail_special=%0d",
             nlegal, nfail, nspecial, nfail_special);
    $display("[SUMMARY] status=%s", ((nfail == 0) && (nfail_special == 0)) ? "PASS" : "FAIL");
    $finish;
  end

endmodule
