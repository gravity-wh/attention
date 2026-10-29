// =====================================================================
//  tb_unit_recip.sv —— recip_unit 对拍（R = RNE(2^40 / T)）
//
//  被测：T ∈ [2^16, 2^20] → R = RNE(2^40/T)，25 位，41 拍长除法 + 1 拍舍入
//
//  ── 为什么不能扫满 2^20 个 T ────────────────────────────────────────
//  每个 T 要 ~46 拍，1M 个点就是 4600 万拍，仿真时间比收益大得多。
//  改成分层，每层都针对一种"会错的方式"：
//
//    A. 连续窗口   T ∈ [65536, 65536+4095]   逐值扫
//                   —— 商从 2^24 开始缓慢下降，能抓"商的第 24/25 位接错"
//    B. 2 的幂 ±小块   T = 2^k + δ, δ ∈ {0,±1,±2,±3,±7}, k = 16..20
//                   —— **整除点**：T 为 2 的幂时 2^41/T 是整数，
//                      2^40/T 正好落在 .5 的舍入边界上，RNE 的"取偶"
//                      只在这些点上能被验证。这是本单元最关键的一组。
//    C. 全程扫掠   T ∈ [65536, 2^20]，步长 61（互质，覆盖所有低位组合）
//    D. 随机       500 点
//    E. 契约外     T = 0 / 1 / 2 / 65535：只验"不死锁、无 X"，不比数值
//                   （商超出 25 位，本来就不可表示；T=0 有显式防御）
//
//  ── 判据 ────────────────────────────────────────────────────────────
//    参考值按 fx.h:fx_rne_div() 的语义逐行转写（整数除 + 余数判定）。
//    这里不追求算法独立：fx_rne_div 就是这条判据的定义本身，
//    RTL 的恢复余数法才是"另一种实现"。
// =====================================================================
`timescale 1ns/1ps
module tb_unit_recip;
  import attn_pkg::*;
  import unit_ref_pkg::*;

  logic        clk;
  logic        rst_n, start, busy, done;
  logic [20:0] t_sum;
  logic [24:0] r_out;

  recip_unit dut (.clk(clk), .rst_n(rst_n), .start(start),
                  .t_sum(t_sum), .r_out(r_out), .busy(busy), .done(done));

  // 2ns 周期：这里只验功能，不关心真实频率，跑快一点。
  always #1 clk = ~clk;

  int     ntot, nfail, nout;
  int     cyc_min, cyc_max;
  longint ev, t;

  localparam longint T_LO = 65536;         // 2^16：T 的最小值（d=0 时 e=65536）
  localparam longint T_HI = 1048576;       // 2^20：16 个元素各满量程的上界

  initial begin
    clk    = 1'b0;
    rst_n  = 1'b0;
    start  = 1'b0;
    t_sum  = 21'd0;
    ntot   = 0; nfail = 0; nout = 0;
    cyc_min = 1 << 30; cyc_max = 0;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    $display("[UNIT] name=recip_unit 契约域 T=[%0d, %0d] 判据 R=RNE(2^%0d/T)",
             T_LO, T_HI, RECIP_SH);

    // ---------------- A. 连续窗口 ----------------
    t = T_LO;
    while (t < T_LO + 4096) begin
      run_t(t, 1'b1, "");
      t = t + 1;
    end
    $display("[UNIT]   A 连续窗口完成：累计 %0d 点，失配 %0d", ntot, nfail);

    // ---------------- B. 2 的幂及邻域（舍入边界全在这）----------------
    for (int k = 16; k <= 20; k++) begin
      for (int dlt = -7; dlt <= 7; dlt++) begin
        t = (longint'(1) << k) + dlt;
        if (t >= T_LO && t <= T_HI) run_t(t, 1'b1, "pow2邻域");
      end
    end
    $display("[UNIT]   B 2 的幂邻域完成：累计 %0d 点，失配 %0d", ntot, nfail);

    // ---------------- C. 全程扫掠（步长 61，与 2 的幂互质）----------------
    t = T_LO;
    while (t <= T_HI) begin
      run_t(t, 1'b1, "");
      t = t + 61;
    end
    $display("[UNIT]   C 全程扫掠完成：累计 %0d 点，失配 %0d", ntot, nfail);

    // ---------------- D. 随机 ----------------
    for (int i = 0; i < 500; i++) begin
      t = T_LO + (longint'($urandom()) % (T_HI - T_LO + 1));
      run_t(t, 1'b1, "");
    end

    // ---------------- E. 契约外：只验不死锁 / 无 X ----------------
    run_t(0,    1'b0, "T=0 除零防御");
    run_t(1,    1'b0, "T=1");
    run_t(2,    1'b0, "T=2");
    run_t(65535,1'b0, "T=65535");

    $display("[UNIT]   时延范围：%0d ~ %0d 拍（文档标称 41+1）", cyc_min, cyc_max);
    $display("[UNIT] name=recip_unit checked=%0d fail=%0d out_of_contract=%0d",
             ntot, nfail, nout);
    $display("[SUMMARY] status=%s", (nfail == 0) ? "PASS" : "FAIL");
    $finish;
  end

  // 跑一个 T。chk=0 时只检查"能返回、无 X"。
  task automatic run_t(input longint T, input bit chk, input string tag);
    int     cyc;
    longint got;

    @(negedge clk);
    t_sum = 21'(T);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    cyc = 0;
    while (!done && cyc < 200) begin
      @(negedge clk);
      cyc = cyc + 1;
    end

    if (cyc >= 200) begin
      nfail++;
      $display("[UNIT]   ✗ T=%0d 超过 200 拍未 done（FSM 卡住）", T);
    end else begin
      got = longint'(r_out);
      if (cyc < cyc_min) cyc_min = cyc;
      if (cyc > cyc_max) cyc_max = cyc;
      if (chk) begin
        ntot++;
        ev = recip_ref(T);
        if ($isunknown(r_out) || got !== ev) begin
          nfail++;
          if (nfail <= 10)
            $display("[UNIT]   ✗ T=%0d %s got=%0d exp=%0d (差 %0d)",
                     T, tag, got, ev, got - ev);
        end
      end else begin
        nout++;
        if ($isunknown(r_out)) begin
          nfail++;
          $display("[UNIT]   ✗ T=%0d %s 输出是 X", T, tag);
        end else begin
          $display("[UNIT]   · T=%0d %s → %0d（契约外，不比数值）", T, tag, got);
        end
      end
    end

    // FSM 需要 2 拍回到 idle（ph: 1 → 2 → 0），再开始下一个
    repeat (2) @(negedge clk);
  endtask

endmodule
