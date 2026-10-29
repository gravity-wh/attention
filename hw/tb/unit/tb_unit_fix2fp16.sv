// =====================================================================
//  tb_unit_fix2fp16.sv —— fix2fp16 穷举 + 分层对拍
//
//  被测：s(32).Y_FRAC 定点 → FP16 位模式（RNE）
//  输入空间 2^32，无法真穷举，所以按"分支"分层，每一层都扫满：
//
//    A. 全覆盖段   |y| <= 2^17，逐值扫（262145 点）
//                  —— 覆盖"位数够，直接左对齐不涉及舍入"和
//                     "需要右移 + RNE"两个分支的全部组合
//    B. 进位边界   y = ±(2^p ± 0..8)、±(2^(p+1)-1)，p = 0..31
//                  —— 尾数 1.111...1 + RNE 进到 2.0 的那一拍最容易错
//    C. 特殊值     0 / ±1 / ±1023 / ±1024 / ±2048 / ±(2^31-1) / INT32_MIN
//                  —— INT32_MIN 取绝对值会溢出，是最阴的一个点
//    D. 随机       20 万点全 32 位空间均匀抽样（$urandom 固定种子）
//
//  ── 判据 ────────────────────────────────────────────────────────────
//    期望值 = f16_from_r(y * 2^-Y_FRAC)，按 fp16.h:d_to_f16() 的语义用实数
//    实现；RTL 走的是"优先编码器 + 取 11 位 + RNE"，两条路径独立。
//
//  ── 附带的覆盖率证据 ────────────────────────────────────────────────
//    统计每个分支被命中多少次（小值直取 / 舍入 / 溢出成 inf / 归零），
//    如果某个分支 0 次命中，说明"穷举"名不副实。
// =====================================================================
`timescale 1ns/1ps
module tb_unit_fix2fp16;
  import attn_pkg::*;
  import unit_ref_pkg::*;

  localparam int FRAC = Y_FRAC;

  logic signed [31:0] y;
  logic        [15:0] fp;

  fix2fp16 #(.FRAC(FRAC)) dut (.y(y), .fp(fp));

  int     ntot, nfail;
  int     c_small, c_round, c_inf, c_zero;
  logic [15:0] exp_v, got_v;
  longint yv, mag, v, eff;

  initial begin
    ntot = 0; nfail = 0;
    c_small = 0; c_round = 0; c_inf = 0; c_zero = 0;

    $display("[UNIT] name=fix2fp16 frac=%0d domain=分层穷举", FRAC);

    // ---------------- A. |y| <= 2^17 全覆盖 ----------------
    v = -(1 << 17);
    while (v <= (1 << 17)) begin
      check_y(v, "");
      v = v + 1;
    end

    // ---------------- B. 每个指数量级的进位边界 ----------------
    for (int p = 0; p <= 31; p++) begin
      for (int dlt = -8; dlt <= 8; dlt++) begin
        yv = (longint'(1) << p) + dlt;
        if (yv >= 0 && yv <= 32'sh7FFFFFFF) begin
          check_y( yv, "");
          check_y(-yv, "");
        end
      end
      yv = (longint'(2) << p) - 1;               // 2^(p+1)-1，全 1 尾数
      if (yv <= 32'sh7FFFFFFF) begin
        check_y( yv, "");
        check_y(-yv, "");
      end
    end

    // ---------------- C. 特殊值 ----------------
    check_y(0,        "y=0");
    check_y(1,        "|y|=1");
    check_y(-1,       "-1");
    check_y(1023,     "1023（尾数全 1 下界）");
    check_y(1024,     "1024（隐含位）");
    check_y(2047,     "2047（尾数全 1）");
    check_y(2048,     "2048（进位到下一指数）");
    check_y(-2048,    "-2048");
    check_y(32'sh7FFFFFFF, "INT32_MAX（必溢出）");
    check_y(32'sh80000000, "INT32_MIN（取绝对值溢出）");

    // ---------------- D. 随机 ----------------
    for (int i = 0; i < 200000; i++) begin
      check_y(longint'($urandom()), "");
    end

    $display("[UNIT]   分支命中：小值直取=%0d  舍入=%0d  溢出inf=%0d  归零=%0d",
             c_small, c_round, c_inf, c_zero);
    $display("[UNIT] name=fix2fp16 checked=%0d fail=%0d", ntot, nfail);
    $display("[SUMMARY] status=%s", (nfail == 0) ? "PASS" : "FAIL");
    $finish;
  end

  // 单点检查
  task automatic check_y(input longint v, input string tag);
    y = 32'(v);
    #1;
    got_v = fp;

    // 端口只有 32 位：v 落在 [2^31, 2^32) 时会被截断成负数。
    // 参考值必须按"端口实际收到的那个数"算，否则比的是两个不同的输入
    // —— 这一条曾让 20 万个随机点报假失配（tb 的错，不是 DUT 的错）。
    eff   = longint'($signed(y));
    exp_v = f16_from_r(real'(eff) / pow2i(FRAC));
    ntot++;

    // 分支计数（只按输入幅值分类，与 RTL 内部实现无关）
    mag = (eff < 0) ? -eff : eff;
    if (mag == 0)            c_zero++;
    else if (mag < (1 << 11)) c_small++;
    else if (exp_v[14:10] == 5'h1F) c_inf++;
    else                     c_round++;

    if ($isunknown(fp) || got_v !== exp_v) begin
      nfail++;
      if (nfail <= 10)
        $display("[UNIT]   ✗ y=%0d %s got=%04h exp=%04h", eff, tag, got_v, exp_v);
    end
  endtask

endmodule
