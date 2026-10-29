# =====================================================================
#  方案注册表 —— 全工程唯一真源（single source of truth）
#  Makefile 与 flow/ 下的脚本都从这里读，任何地方不要硬编码方案名。
#
#  命名铁律（这条守住了，验证代码只用写一份）：
#    1. 每个方案的顶层模块名 = top_<variant>
#    2. 三个顶层的端口列表（interface）必须逐位一致
#    3. 每个方案一个 filelist.f，位置 hw/rtl/<variant>/filelist.f
#
#  注意：值不要和行尾注释挤在一起（make 会把 # 前的空格算进值里），
#        注释统一写在上一行。
# =====================================================================

VARIANTS := ref varA varB

# ---- ref：统一参考实现（评分基准）-----------------------------------
# 铁律：只允许做「工艺适配」（换库、按库重设驱动/尺寸），结构上不许改差
# —— 改差了综合效率那 40 分就失真了。
top_ref := top_ref
clock_ref := 100
sdc_ref := clk_ref.sdc
desc_ref := 统一参考实现：单 MAC 串行点积 + 线性扫描 Softmax + 串行加权求和

# ---- varA：方案 A ---------------------------------------------------
top_varA := top_varA
clock_varA := 200
sdc_varA := clk_varA.sdc
desc_varA := 方案A：8 路并行点积（KE 阵列）

# ---- varB：方案 B（与 A 至少隔离一个主要变量）------------------------
top_varB := top_varB
clock_varB := 200
sdc_varB := clk_varB.sdc
desc_varB := 方案B：脉动阵列 + 在线 Softmax

# ---- PVT 角 ----------------------------------------------------------
# 已移到 config/pdk.mk：角的选择与它对应的 .lib 是同一件事，
# 分开写就会出现"标签写 ss、实际加载了 tt 的库"这种查不出来的错。
# 那边还负责工艺库路径、驱动单元、负载、uncertainty 等综合约束。

# ---- 内部数值格式：Q/K/V 定点位宽 —— 全工程唯一真源 -------------------
#   qb_<variant> 有符号总位宽，qf_<variant> 小数位（范围 ±2^(qb-qf-1) = ±4）
#   lut_<variant> exp2 的 LUT 索引位（4 -> 16 段 + 1 端点）
#
#   为什么不是三套都一样：
#     ref 是「统一参考实现」，要贴近题面的 FP16 语义，所以给足 16 bit，
#     它在效率对比里充当"没做量化优化"的那个基线。
#     varA/varB 才承载自主设计（量化 + 结构），用 width_sweep 选出的工作点
#     10 bit（docs/theory/01-数值格式设计.md §4：RMSE 余量 15×）。
#     这不是"同条件对照"破例：varA vs varB 格式完全一致，隔离的是结构；
#     ref vs varA 的差值是"不做优化 vs 做优化"的总账，40 分要报的正是这笔账。
#
#   改这三行必须重跑 make vec（每个方案一次），否则向量与 RTL 对不上。
qb_ref  := 16
qf_ref  := 13
lut_ref := 4

qb_varA  := 10
qf_varA  := 7
lut_varA := 4

qb_varB  := 10
qf_varB  := 7
lut_varB := 4
