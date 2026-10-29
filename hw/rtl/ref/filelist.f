// =====================================================================
//  方案 ref —— 统一参考实现（评分基准）
//
//  这份 filelist 同时是「仿真」和「综合」的唯一输入 —— 不要另写一份，
//  否则仿真过的和综合掉的不是同一份代码，这是最经典的翻车方式。
//
//  路径约定：全部相对 hw/ 目录（所有流程都在 hw/ 下执行）
//  编译顺序：common(包/接口) → core(共享数据通路) → 本方案(编排逻辑)
//  顺序不能乱：SV 的 package / interface 必须先于使用者编译。
// =====================================================================
+incdir+rtl/common

// ---- 1. 公共层：三个方案共用 ----
rtl/common/attn_pkg.sv
rtl/common/attn_if.sv

// ---- 2. 共享数据通路：三方案尽量复用，以保「其余条件一致」----
// rtl/core/fp16_mul.sv
// rtl/core/fp16_add.sv
// rtl/core/exp_lut.sv
// rtl/core/mac_lane.sv
// rtl/core/sram_wrap.sv

// ---- 3. 本方案独有：只有编排/调度逻辑 ----
// rtl/ref/top_ref.sv
// rtl/ref/seq_engine.sv
