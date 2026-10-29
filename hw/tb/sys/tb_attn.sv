// =====================================================================
//  tb_attn.sv —— 三方案共用的自检测试平台（一份代码，三个 DUT）
//
//  ── 为什么只有一份 tb ────────────────────────────────────────────────
//    题目要求"同条件对照"。如果每个方案各写一个 tb，那 tb 本身的差异
//    就成了不可控变量；而且改动三个 tb 必然有一处会漏，对比就失真。
//    这里 DUT 用宏注入：
//        vcs ... +define+DUT=top_ref   → 例化 top_ref
//    三个方案共用同一份驱动、同一份判据、同一份覆盖率。
//
//  ── 两条判据同时成立才算 PASS ────────────────────────────────────────
//    1) 逐位一致：输出 FP16 必须与 C 定点模型 bit-exact
//       （题目原文：「建立与 RTL 输出逐位一致的软件模型」）
//    2) 精度达标：对 float64 参考的 RMSE <= 0.06、最大绝对误差 <= 0.20
//       （评分判据）
//    只过 (1) 说明 RTL 忠实于一个错误的模型；只过 (2) 说明模型和 RTL 不是一回事。
//
//  ── plusargs ─────────────────────────────────────────────────────────
//    +VECDIR=<dir>   向量目录（含 <cat>_<idx>_qkv/exp/ref.hex）
//    +CAT=<name>     类别：random zero extreme cancel reset cont
//    +N=<n>          任务数
//    +VERBOSE=1      打印每个任务的明细与失配元素
//    +DUMP=1         需要时才 dump 波形（默认关，波形别开着跑回归）
//    +TOL_SCALE=1.0  判据缩放（调试用，1.0 = 正式判据，报告里不许改）
//
//  编译宏：+define+DUT=top_xxx      指定被测顶层
// =====================================================================
`timescale 1ns/1ps
`include "attn_ports.svh"

module tb_attn;

  import attn_pkg::*;
  import attn_tb_pkg::*;

  // ---------------------------------------------------------------- 参数
  parameter int CLK_MHZ = 100;
  localparam real HALF_NS = 500.0 / CLK_MHZ;

  localparam int NM = attn_pkg::N;        // 16
  localparam int NE = attn_pkg::NELEM;    // 256
  localparam int TIMEOUT = 200000;        // 单任务超时（周期）

  // 判据（与 model/main.c 一致）
  localparam real RMSE_LIMIT  = 0.06;
  localparam real MAXAE_LIMIT = 0.20;

`ifndef DUT
  `define DUT top_ref
`endif
// 供日志显示用；由流程脚本用 +define+DUT_NAME="top_xxx" 注入。
// 不用 `"DUT`" 字符串化：实测 VCS 会原样打印 "DUT" 而不是展开后的名字。
`ifndef DUT_NAME
  `define DUT_NAME "未知（未传 +define+DUT_NAME）"
`endif

  // ---------------------------------------------------------------- 时钟
  logic clk = 1'b0;
  always #(HALF_NS) clk = ~clk;

  // ---------------------------------------------------------------- DUT
  logic        rst_n;
  logic        ld_en;
  logic [1:0]  ld_sel;
  logic [7:0]  ld_addr;
  logic [15:0] ld_data;
  logic        start;
  logic        busy;
  logic        done;
  logic        o_vld;
  logic [7:0]  o_addr;
  logic [15:0] o_data;

  `DUT u_dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .ld_en   (ld_en),
    .ld_sel  (ld_sel),
    .ld_addr (ld_addr),
    .ld_data (ld_data),
    .start   (start),
    .busy    (busy),
    .done    (done),
    .o_vld   (o_vld),
    .o_addr  (o_addr),
    .o_data  (o_data)
  );

  // ---------------------------------------------------------------- 向量
  logic [15:0]      qkv [0:3*NE-1];   // Q[0..255] K[256..511] V[512..767]
  logic [15:0]      expv[0:NE-1];     // 逐位一致的期望输出
  longint unsigned  refv[0:NE-1];     // float64 参考（$bitstoreal 还原）
  logic [15:0]      outv[0:NE-1];     // DUT 输出
  logic [15:0]      outv_first[0:NE-1]; // reset 用例：复位前那一轮的输出

  // ---------------------------------------------------------------- 统计
  int  n_task_pass = 0;
  int  n_task_fail = 0;
  int  n_proto_warn = 0;
  real worst_rmse = 0.0;
  real worst_ae   = 0.0;
  int  worst_mism = 0;
  int  lat_min = 0, lat_max = 0, lat_sum = 0;
  string cat_name = "random";

  // ---------------------------------------------------------------- 波形
  initial begin
    bit dump;
    if ($value$plusargs("DUMP=%d", dump) && dump) begin
      $dumpfile("tb_attn.vcd");
      $dumpvars(0, tb_attn);
      $display("[tb] 波形已开启 → tb_attn.vcd（回归时请关掉，会拖慢一个数量级）");
    end
  end

  // ---------------------------------------------------------- 协议监视
  // 只做"记录"，不做"判决"：busy 与 o_vld 的边界时序在不同实现里可能
  // 相差一拍，把它当硬失败会产生假告警，反而掩盖真问题。
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if (o_vld === 1'b1 && busy === 1'b0) n_proto_warn++;
      if (done  === 1'b1 && rst_n === 1'b0) n_proto_warn++;
    end
  end

  // ------------------------------------------------------------ 覆盖率
  // 全部用整数桶，避免 real 桶在不同仿真器上的边界差异。
  int cov_cat   = 0;   // 0..5 对应六类
  int cov_lat_b = 0;   // 0=短 1=中 2=长
  int cov_mis_b = 0;   // 0=无失配 1=有失配
  int cov_rm_b  = 0;   // rmse*10000，桶化后观察分布

  covergroup cg_task;
    option.per_instance = 1;
    cp_cat  : coverpoint cov_cat   { bins b[] = {[0:5]}; }
    cp_lat  : coverpoint cov_lat_b { bins short_lat = {0}; bins mid_lat = {1}; bins long_lat = {2}; }
    cp_mis  : coverpoint cov_mis_b { bins clean = {0}; bins dirty = {1}; }
    cp_rm   : coverpoint cov_rm_b  { bins rm_tiny = {[0:99]}; bins rm_low = {[100:599]};
                                     bins rm_mid  = {[600:10000]}; bins rm_over = {[10001:$]}; }
    x_lat_mis : cross cp_lat, cp_mis;
  endgroup

  cg_task cg = new();

  // ---------------------------------------------------------------- 工具
  task automatic do_reset(input int cycles);
    rst_n = 1'b0;
    ld_en = 1'b0; ld_sel = 2'd0; ld_addr = 8'd0; ld_data = 16'd0;
    start = 1'b0;
    repeat (cycles) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
  endtask

  function automatic bit file_exists(input string fn);
    int fd;
    fd = $fopen(fn, "r");
    if (fd == 0) return 1'b0;
    $fclose(fd);
    return 1'b1;
  endfunction

  // 读向量。
  // 这里必须自己做存在性检查：$readmemh 打不开文件时**只打 warning 不报错**，
  // 数组会保持 X，于是整轮比对变成"和垃圾数据对比"，最后报一个看起来像
  // DUT bug 的 FAIL。这种假故障排查起来极费时间，必须挡在源头。
  //
  // 注意：这里用 $display + $finish，**不要用 $fatal**。
  // 实测 VCS 在 $fatal 之后会卡约 90 秒才退出（-debug_access+all 下更明显），
  // 而流程脚本本来就是解析 [SUMMARY] 行来判 PASS/FAIL，不依赖退出码。
  task automatic load_vec(input string base);
    string fn;
    int    nx;

    fn = {base, "_qkv.hex"};
    if (!file_exists(fn)) begin
      $display("[FATAL] 向量缺失: %0s", fn);
      $display("        → 先跑 make vec SEED=<seed> MODE=smoke|full");
      $finish;
    end
    $readmemh(fn, qkv);

    fn = {base, "_exp.hex"};
    if (!file_exists(fn)) begin
      $display("[FATAL] 向量缺失: %0s", fn);
      $finish;
    end
    $readmemh(fn, expv);

    fn = {base, "_ref.hex"};
    if (!file_exists(fn)) begin
      $display("[FATAL] 向量缺失: %0s", fn);
      $finish;
    end
    $readmemh(fn, refv);

    // 再查一遍有没有残留 X（文件少写了几行也会走到这里）
    nx = 0;
    for (int i = 0; i < 3*NE; i++) if (^qkv[i] === 1'bx) nx++;
    if (nx != 0) begin
      $display("[FATAL] %0s_qkv.hex 有 %0d 个 X/未赋值元素，文件不完整", base, nx);
      $finish;
    end
    nx = 0;
    for (int i = 0; i < NE; i++) if (^expv[i] === 1'bx || ^refv[i] === 1'bx) nx++;
    if (nx != 0) begin
      $display("[FATAL] %0s 的 exp/ref 有 %0d 个 X/未赋值元素，文件不完整", base, nx);
      $finish;
    end
  endtask

  // 装载 3×256 个元素。地址 0..255 行主序，ld_sel: 0=Q 1=K 2=V
  task automatic drive_load();
    for (int sel = 0; sel < 3; sel++) begin
      for (int a = 0; a < NE; a++) begin
        @(negedge clk);
        ld_en   = 1'b1;
        ld_sel  = sel[1:0];
        ld_addr = a[7:0];
        ld_data = qkv[sel*NE + a];
      end
    end
    @(negedge clk);
    ld_en = 1'b0;
  endtask

  // 跑一个任务：握手 + 收输出 + 协议检查
  //
  // 关键点：done 与第一拍 o_vld 可能是同一个周期（流式输出的实现都是这样）。
  // 早期版本先等 done 再开始采样，结果第 0 个元素永远漏掉——真实 DUT 会
  // 因此被冤枉成「丢数据」。所以这里每一拍都采样，done 只用来记时延。
  task automatic run_task(output int lat, output int ord_err, output int recv);
    int n;
    lat = -1; ord_err = 0; recv = 0;

    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    n = 0;
    while (recv < NE && n < TIMEOUT) begin
      @(posedge clk);
      n++;
      if (lat < 0 && done === 1'b1) lat = n;
      if (o_vld === 1'b1) begin
        if (o_addr !== recv[7:0]) ord_err++;
        outv[o_addr] = o_data;
        recv++;
      end
    end

    if (recv < NE) $error("输出不全：只收到 %0d/%0d 个元素", recv, NE);
    if (lat < 0)   $error("超时：start 后 %0d 周期未收到 done", TIMEOUT);
  endtask

  // 两条判据一起判
  task automatic check_task(output bit pass, output int mismatch,
                            output real rmse, output real maxae, output int n_nonfinite);
    real se, e, y;
    se = 0.0; maxae = 0.0; mismatch = 0; n_nonfinite = 0;

    for (int i = 0; i < NE; i++) begin
      if (outv[i] !== expv[i]) begin
        mismatch++;
        if (mismatch <= 5)
          $display("  [MISMATCH] i=%0d (row %0d,col %0d) got=%04h exp=%04h",
                   i, i/NM, i%NM, outv[i], expv[i]);
      end
      if (!attn_pkg::is_finite(outv[i])) n_nonfinite++;
      y = fp16_to_real(outv[i]);
      e = y - $bitstoreal(refv[i]);
      se += e * e;
      if ($abs(e) > maxae) maxae = $abs(e);
    end
    rmse = $sqrt(se / NE);

    pass = (mismatch == 0) && (rmse <= RMSE_LIMIT) && (maxae <= MAXAE_LIMIT)
           && (n_nonfinite == 0);
  endtask

  task automatic upd_cov(input int lat, input int mismatch, input real rmse);
    cov_lat_b = (lat < 300) ? 0 : (lat < 3000) ? 1 : 2;
    cov_mis_b = (mismatch == 0) ? 0 : 1;
    cov_rm_b  = int'(rmse * 10000.0);
    cg.sample();
  endtask

  // ---------------------------------------------------------------- 主流程
  string vecdir;
  int    ntasks;
  bit    verbose;
  int    lat, ord, recv, mismatch, nf, rdiff;
  bit    passv;
  real   rmse, maxae;
  string base;
  int    cand;

  initial begin
    if (!$value$plusargs("VECDIR=%s", vecdir)) vecdir = "tb/vectors/s20260101";
    if (!$value$plusargs("CAT=%s", cat_name))  cat_name = "random";
    if (!$value$plusargs("N=%d", ntasks))      ntasks = 2;
    if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;

    case (cat_name)
      "random"  : cand = 0;
      "zero"    : cand = 1;
      "extreme" : cand = 2;
      "cancel"  : cand = 3;
      "reset"   : cand = 4;
      "cont"    : cand = 5;
      default   : cand = 0;
    endcase
    cov_cat = cand;

    $display("");
    $display("================================================================");
    $display(" tb_attn —— DUT=%0s  cat=%0s  n=%0d  clk=%0d MHz",
             `DUT_NAME, cat_name, ntasks, CLK_MHZ);
    $display(" 判据：逐位一致 + RMSE<=%0.3f + max|e|<=%0.3f", RMSE_LIMIT, MAXAE_LIMIT);
    $display(" 向量：%0s", vecdir);
    $display("================================================================");

    do_reset(5);

    for (int t = 0; t < ntasks; t++) begin
      base = $sformatf("%s/%s_%0d", vecdir, cat_name, t);
      if (verbose) $display("[task %0d] %0s", t, base);
      load_vec(base);

      // ---- 判据自检：把期望值直接当输出，判据必须判 PASS ----
      // 这一条是为了防止"判据本身写错导致永远 PASS/永远 FAIL"——
      // 那种错误比 RTL 的 bug 更难发现。
      if ($test$plusargs("SELFTEST") && t == 0) begin
        for (int i = 0; i < NE; i++) outv[i] = expv[i];
        check_task(passv, mismatch, rmse, maxae, nf);
        $display("[SELFTEST] 判据自检 → %0s  rmse=%0.6f  max|e|=%0.6f  mism=%0d",
                 passv ? "PASS" : "FAIL", rmse, maxae, mismatch);
        if (!passv) $display("[SELFTEST] 判据实现有问题：把期望值直接当输出都过不了");
        $finish;
      end

      // ---- 装载 ----
      if (cat_name == "cont") begin
        // 连续任务：不复位，直接接着上一轮的内部状态跑
      end else begin
        do_reset(3);
      end
      drive_load();

      // ---- 运行 ----
      run_task(lat, ord, recv);
      if (lat < 0) begin
        n_task_fail++;
        continue;
      end

      // ---- reset 用例：先存一轮，复位后重跑，两次必须逐位相同 ----
      if (cat_name == "reset") begin
        for (int i = 0; i < NE; i++) outv_first[i] = outv[i];
        do_reset(3);
        drive_load();
        run_task(lat, ord, recv);
        if (lat < 0) begin n_task_fail++; continue; end

        rdiff = 0;
        for (int i = 0; i < NE; i++) if (outv[i] !== outv_first[i]) rdiff++;
        if (rdiff != 0)
          $display("  [RESET] 复位后输出与复位前不一致：%0d 个元素不同", rdiff);
        else if (verbose)
          $display("  [RESET] 复位前后逐位一致 ✓");
        mismatch += rdiff;
      end

      // ---- 判据 ----
      check_task(passv, mismatch, rmse, maxae, nf);
      if (ord != 0) begin
        $display("  [PROTO] o_addr 未严格递增，异常 %0d 次", ord);
        passv = 1'b0;
      end
      if (recv != NE) passv = 1'b0;

      upd_cov(lat, mismatch, rmse);

      if (lat < lat_min || lat_min == 0) lat_min = lat;
      if (lat > lat_max) lat_max = lat;
      lat_sum += lat;
      if (rmse > worst_rmse) worst_rmse = rmse;
      if (maxae > worst_ae)  worst_ae  = maxae;
      if (mismatch > worst_mism) worst_mism = mismatch;

      if (passv) begin
        n_task_pass++;
        if (verbose)
          $display("[task %0d] PASS  lat=%0d  rmse=%0.6f  max|e|=%0.6f", t, lat, rmse, maxae);
      end else begin
        n_task_fail++;
        $display("[task %0d] FAIL  lat=%0d  mismatch=%0d  rmse=%0.6f  max|e|=%0.6f  nonfinite=%0d",
                 t, lat, mismatch, rmse, maxae, nf);
      end
    end

    // ---- 汇总 ----
    $display("----------------------------------------------------------------");
    $display(" 类别 %-10s  任务 %0d/%0d 通过", cat_name, n_task_pass, n_task_pass + n_task_fail);
    if (n_task_pass + n_task_fail > 0)
      $display(" 时延 lat: min=%0d avg=%0d max=%0d 周期（@%0d MHz）",
               lat_min, lat_sum / (n_task_pass + n_task_fail), lat_max, CLK_MHZ);
    $display(" 最差 RMSE=%0.6f  最差 max|e|=%0.6f  最大逐位失配=%0d 个元素",
             worst_rmse, worst_ae, worst_mism);
    if (n_proto_warn > 0)
      $display(" 协议告警 %0d 次（o_vld/busy 时序边界，非致命）", n_proto_warn);
    $display(" 覆盖率：cat=%0s lat_b=%0d mism_b=%0d", cat_name, cov_lat_b, cov_mis_b);

    // 机器可读汇总行：flow/ 下的脚本只认这一行，不要改成中文去 parse
    $display("[SUMMARY] cat=%0s tasks=%0d pass=%0d fail=%0d lat_min=%0d lat_avg=%0d lat_max=%0d rmse=%0.6f maxae=%0.6f mism=%0d status=%0s",
             cat_name, n_task_pass + n_task_fail, n_task_pass, n_task_fail,
             lat_min,
             (n_task_pass + n_task_fail) ? (lat_sum / (n_task_pass + n_task_fail)) : 0,
             lat_max, worst_rmse, worst_ae, worst_mism,
             (n_task_fail == 0) ? "PASS" : "FAIL");

    if (n_task_fail == 0) begin
      $display(" 结果：PASS");
      $display("================================================================");
    end else begin
      $display(" 结果：FAIL（%0d 个任务未通过）", n_task_fail);
      $display("================================================================");
    end
    $finish;
  end

endmodule
