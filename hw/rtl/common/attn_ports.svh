// =====================================================================
//  attn_ports.svh —— 三方案的统一端口契约
//
//  为什么是宏头文件，不是 SystemVerilog interface？
//    实测见 hw/README.md「工具与语言子集」：
//      · Icarus Verilog 12 不支持 interface 出现在端口列表（modport 直接语法错误）
//      · DC / Genus 综合 SV interface 需要额外开关，面积数字容易踩流程坑
//    宏头文件在 VCS / Verilator / iverilog / DC / Genus 上全部通吃。
//
//  用法（三个方案的顶层必须一字不差地这样写）：
//      module top_ref  `ATTN_TOP_PORTS;
//      module top_varA `ATTN_TOP_PORTS;
//      module top_varB `ATTN_TOP_PORTS;
//
//  改这里 = 同时改三套。任何方案都不许私自加减端口。
//
//  ── 握手时序（tb 按这份契约写，DUT 必须遵守）─────────────────────────
//   1. 复位：rst_n 低至少 1 个周期；期间 busy/done/o_vld 均为 0。
//   2. 装载：ld_en=1 时，每个 posedge 把 ld_data 写入 matrix[ld_sel][ld_addr]。
//      共 3×256 次，地址 0..255，行主序。
//   3. 启动：busy=0 时给 start 一个单周期脉冲 → 下一周期 busy 拉高。
//   4. 完成：算完当拍 done 拉高一个周期（可与 o_vld 同时）。
//   5. 输出：从 o_addr=0 开始，o_vld=1 的每一拍输出一个元素，
//      **地址必须严格递增 0,1,2,…,255**（tb 用递增做协议检查）。
//      输出完后 busy 拉低，回到可接收下一次 start 的状态。
// =====================================================================
`ifndef ATTN_PORTS_SVH
`define ATTN_PORTS_SVH

`define ATTN_TOP_PORTS (                                   \
  /* ---- 全局 ---- */                                      \
  input  logic         clk,                                 \
  input  logic         rst_n,                               \
                                                            \
  /* ---- 装载通道：Q/K/V 矩阵逐元素写入 ---- */              \
  input  logic         ld_en,                               \
  input  logic [1:0]   ld_sel,     /* 0=Q 1=K 2=V */        \
  input  logic [7:0]   ld_addr,    /* 0..255, 行主序 */      \
  input  logic [15:0]  ld_data,                             \
                                                            \
  /* ---- 任务控制：计时窗口 start→done ---- */                \
  input  logic         start,                               \
  output logic         busy,                                \
  output logic         done,                                \
                                                            \
  /* ---- 结果输出：O 逐元素读出，地址严格递增 ---- */          \
  output logic         o_vld,                               \
  output logic [7:0]   o_addr,                              \
  output logic [15:0]  o_data                               \
)

`endif // ATTN_PORTS_SVH
