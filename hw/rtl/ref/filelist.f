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
+incdir+rtl/core

// ---- 1. 公共层：attn_pkg.sv（类型/参数）+ attn_ports.svh（统一端口宏）----
rtl/common/attn_pkg.sv
rtl/common/attn_ports.svh

// ---- 2. 共享数据通路：三方案尽量复用，以保「其余条件一致」----
//  这五个文件是「数值契约的硬件化身」：改任何一个都等于改三套方案的数值结果，
//  所以它们必须在 core/ 而不是各方案目录下。
rtl/core/attn_math.svh      // RNE 移位 / 饱和 / exp2 LUT（纯函数库）
rtl/core/fp16_quant.sv      // FP16 -> s(QB).QF，装载时做一次
rtl/core/exp2_unit.sv       // 2^(-d)：LUT + 线性插值 + 移位
rtl/core/fix2fp16.sv        // 定点 -> FP16（RNE）
rtl/core/recip_unit.sv      // 每行一次倒数 2^40/T（恢复余数法）

// ---- 3. 本方案独有：只有编排/调度逻辑 ----
rtl/ref/top_ref.sv
