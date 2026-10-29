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

// ---- 1. 公共层：三方案共用（必须与 ref、varB 逐行一致）----
rtl/common/attn_pkg.sv
rtl/common/attn_if.sv

// ---- 2. 共享数据通路 ----
// rtl/core/fp16_mul.sv
// rtl/core/fp16_add.sv
// rtl/core/exp_lut.sv
// rtl/core/mac_lane.sv
// rtl/core/sram_wrap.sv

// ---- 3. 本方案独有 ----
// rtl/varA/top_varA.sv
// rtl/varA/dot8_engine.sv（8 lane 并行点积）
