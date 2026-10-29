// =====================================================================
//  tb_unit_exp2.sv —— exp2_unit 穷举对拍
//
//  被测：d（F=S_FRAC）→ 2^(-d)（F=16，17 位，范围 [0, 65536]）
//  激励：d ∈ [0, EXP_ZERO_N * 2^16] = [0, 1048576] 全扫（1,048,577 点）。
//        这一段覆盖了"结果非零"的全部合法输入；再往上契约规定输出恒为 0，
//        另行抽查。
//
//  ── 为什么这段可以穷举 ────────────────────────────────────────────
//  d 是 S 的差（F=16），输出在 n >= 16 时一律归零，所以有效输入区间
//  只有 2^20 个格点。1M 点对组合逻辑来说就是几秒，没有理由采样。
//
//  ── 三层检查，分开报数（便于定位）────────────────────────────────
//    1) 表本身：把 RTL 里那张 case 表逐项与自己算的 2^(-k/32) 比
//       （32 项，错一项就会被后面 1M 个点淹没，所以先单独查）
//    2) 全扫：d ∈ [0, 16<<16]，逐位一致
//    3) 边界：d 略超区间、2^21、2^24、2^31-1，以及契约外的 d<0
// =====================================================================
`timescale 1ns/1ps
module tb_unit_exp2;
  import attn_pkg::*;
  import unit_ref_pkg::*;
  `include "attn_math.svh"          // 只为取出 RTL 侧的 LUT 做单独校验

  localparam int NMAX = EXP_ZERO_N << 16;   // 1048576

  logic signed [31:0] d;
  logic        [16:0] e;

  exp2_unit dut (.d_fx(d), .e_fx(e));

  int     nfail;
  int     ntot;
  int     tab_fail;
  int     k, v_rtl, v_ref;
  logic [16:0] exp_v, got_v;

  initial begin
    nfail = 0; ntot = 0; tab_fail = 0;

    $display("[UNIT] name=exp2_unit lut_bits=%0d s_frac=%0d domain=%0d",
             EXP_LUT_BITS, S_FRAC, NMAX + 1);

    // ---------------- 1) LUT 表逐项校验 ----------------
    for (k = 0; k <= 32; k++) begin
      v_rtl = int'(attn_exp2_lut(k));
      v_ref = lut_val(k);
      if (v_rtl != v_ref) begin
        tab_fail++;
        $display("[UNIT]   ✗ LUT k=%0d rtl=%0d ref=%0d (差 %0d)",
                 k, v_rtl, v_ref, v_rtl - v_ref);
      end
    end
    $display("[UNIT]   LUT 33 项：错 %0d 项", tab_fail);

    // ---------------- 2) 全扫 ----------------
    for (int i = 0; i <= NMAX; i++) begin
      d = 32'(i);
      #1;
      got_v = e;
      exp_v = exp2_ref(longint'(i), EXP_LUT_BITS, S_FRAC);
      ntot++;
      if ($isunknown(e) || got_v !== exp_v) begin
        nfail++;
        if (nfail <= 8)
          $display("[UNIT]   ✗ d=%0d(t=%0d) got=%0d exp=%0d",
                   i, i, got_v, exp_v);
      end
      if (i != 0 && (i % 262144) == 0)
        $display("[UNIT]   进度 %0d/%0d，累计失配 %0d", i, NMAX, nfail);
    end

    // ---------------- 3) 边界 ----------------
    check_one(32'd0,            17'd65536, "d=0 → 2^0=1.0");
    check_one(32'(NMAX - 1),    0,         "d 略小于归零点");
    check_one(32'(NMAX),        0,         "d 正好归零");
    check_one(32'(NMAX + 1),    0,         "d 略超归零点");
    check_one(32'h00100000,     0,         "d=2^20");
    check_one(32'h01000000,     0,         "d=2^24");
    check_one(32'h7FFFFFFF,     0,         "d=2^31-1（45 位乘积不溢出）");
    // d<0 属于契约外（S - max 理论上恒 >= 0）。RTL 的处理是「按 d=0 钳位」，
    // 于是输出 2^0 = 1.0 而不是 0：这是有意的防御选择，不是漏判 0。
    // 判据只要求"不出 X、不给垃圾"，钳位到 1.0 比给 0 更不容易在下游放大误差。
    check_one(-32'sd1,          17'd65536, "d=-1（契约外，按 d=0 钳位）");
    check_one(-32'sd65536,      17'd65536, "d=-2^16（契约外，同上）");

    $display("[UNIT] name=exp2_unit checked=%0d fail=%0d lut_fail=%0d tab_checked=33",
             ntot, nfail, tab_fail);
    $display("[SUMMARY] status=%s", ((nfail == 0) && (tab_fail == 0)) ? "PASS" : "FAIL");
    $finish;
  end

  // 单点检查：既比期望值，也确认没有 X
  task automatic check_one(input logic signed [31:0] dv,
                           input logic        [16:0] ev,
                           input string              name);
    d = dv;
    #1;
    if ($isunknown(e) || e !== ev) begin
      nfail++;
      $display("[UNIT]   ✗ %s : d=%0d got=%0d exp=%0d", name, dv, e, ev);
    end else begin
      $display("[UNIT]   ✓ %s : d=%0d → %0d", name, dv, e);
    end
  endtask

endmodule
