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
//      module top_ref #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
//      module top_varA #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
//      module top_varB #(parameter int SEQ_LEN = 8, D_HEAD = 64) `ATTN_TOP_PORTS;
//
//  改这里 = 同时改三套。任何方案都不许私自加减端口。
// =====================================================================
`ifndef ATTN_PORTS_SVH
`define ATTN_PORTS_SVH

`define ATTN_TOP_PORTS (                              \
  /* ---- 全局 ---- */                                 \
  input  logic         clk,                            \
  input  logic         rst_n,                          \
                                                       \
  /* ---- 装载通道：Q/K/V 矩阵逐元素写入 ---- */         \
  input  logic         ld_en,                          \
  input  logic [1:0]   ld_sel,     /* 0=Q 1=K 2=V */   \
  input  logic [11:0]  ld_addr,                          \
  input  logic [15:0]  ld_data,                          \
                                                       \
  /* ---- 任务控制：计时窗口 start→done ---- */           \
  input  logic         start,                          \
  output logic         busy,                           \
  output logic         done,                           \
                                                       \
  /* ---- 结果输出：O 矩阵逐元素读出 ---- */             \
  output logic         o_vld,                          \
  output logic [11:0]  o_addr,                           \
  output logic [15:0]  o_data                            \
)

// 输出矩阵元素总数（SEQ_LEN × D_HEAD），三方案共用同一套地址约定
`define ATTN_LD_DEPTH (3 * 12'hFFF)

`endif // ATTN_PORTS_SVH
