// =====================================================================
//  attn_tb_pkg.sv —— 测试平台共用的数值工具
//
//  这里只放"让波形和日志能看懂"的东西，不放任何判据。
//  判据全部在 tb 里，避免有人改了这个包就悄悄放松了验收标准。
// =====================================================================
`ifndef ATTN_TB_PKG_SV
`define ATTN_TB_PKG_SV

package attn_tb_pkg;

  // 2 的整数次幂（real）。不用 2.0**k 是因为不同仿真器对 real 幂运算的
  // 精度处理不一致，这里用连乘，结果确定。
  function automatic real pow2i(input int k);
    real r = 1.0;
    if (k >= 0) begin
      for (int i = 0; i < k; i++) r = r * 2.0;
    end else begin
      for (int i = 0; i < -k; i++) r = r / 2.0;
    end
    return r;
  endfunction

  // IEEE 754 binary16 位模式 → real（精确，无舍入）
  function automatic real fp16_to_real(input logic [15:0] h);
    logic s;
    int   e, m;
    real  v;
    s = h[15];
    e = int'(h[14:10]);
    m = int'(h[9:0]);
    if (e == 0)       v = m * pow2i(-24);              // 次正规
    else if (e == 31) v = (m != 0) ? 0.0/0.0 : 1.0/0.0; // nan / inf
    else              v = (1024 + m) * pow2i(e - 25);
    return s ? -v : v;
  endfunction

  // 便于在波形里直接看十进制真值
  function automatic string fp16_str(input logic [15:0] h);
    return $sformatf("%04h(%0.5f)", h, fp16_to_real(h));
  endfunction

endpackage

`endif // ATTN_TB_PKG_SV
