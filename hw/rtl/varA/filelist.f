// =====================================================================
//  方案 varA —— 方案 A —— 8 路并行点积（KE 阵列）
//
//  这份 filelist 同时是「仿真」和「综合」的唯一输入。
//  路径约定：全部相对 hw/ 目录（所有流程都在 hw/ 下执行）
//  编译顺序：common(包/接口) → core(共享数据通路) → 本方案(编排逻辑)
//
//  ⚠ 本方案与其他方案的差异只能出现在第 3 段。
//    若你发现要改 core/ 里共享的东西来让 varA 跑通，先停下来：
//    那说明这个改动要么应做成参数，要么就是你把对比条件破坏了。
// =====================================================================
+incdir+rtl/common
+incdir+rtl/core

// ---- 1. 公共层：三方案共用（必须与 ref、varB 逐行一致）----
rtl/common/attn_pkg.sv
rtl/common/attn_ports.svh
// ⚠ attn_math.svh 必须以**设计文件**形式列在这里，不能只靠模块里的 `include：
//   VCS 把同一批文件当作一个编译单元，头文件守卫（`ifndef ATTN_MATH_SVH）
//   会跨文件生效 —— 谁先 include 谁独占（且是模块内局部），后面所有文件的
//   include 全部被跳过，报 "Identifier not declared"。ref 已经踩过一次。
rtl/core/attn_math.svh

// ---- 2. 共享数据通路（ref 已实现，varA 直接复用）----
rtl/core/fp16_quant.sv
rtl/core/exp2_unit.sv
rtl/core/fix2fp16.sv
rtl/core/recip_unit.sv

// ---- 3. 本方案独有 ----
// rtl/varA/top_varA.sv
// rtl/varA/dot8_engine.sv（8 lane 并行点积）
