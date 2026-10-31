# =====================================================================
#  config/pdk.mk —— 工艺库与综合约束的唯一真源
#
#  为什么单独一个文件：工艺库路径出现在「综合脚本、SDC 生成、报告填报」
#  三个地方。任何一处手写库路径，都会在换角/换库时漏改一处，而漏改的后果
#  不是报错，是"两个方案用了不同的库却没人发现"—— 那 40 分的效率对比直接作废。
#
#  ── 本机可用的库（2026-10-29 实测，2026-10-31 起 SC9MC 为默认）──────
#  VM 上装了两套可综合的标准单元库：
#
#  ★ 默认 PDK：SMIC 40LL（sc9mc base RVT c40，r1p1）—— 真实可流片 40nm 库。
#    · lib/{tt,ss,ff} —— 三个角齐全（1.10 / 0.99 / 1.21 V）
#    · lef/sc9mc_..._base_rvt_c40.lef —— 487 个 MACRO，含真实 SIZE
#    · verilog/sc9mc_....v —— 单元行为模型，**可做门级仿真**（GPDK045 没有）
#    · voltagestorm/*/qrcTechFile_RCgen —— 每角一份寄生提取文件（P&R 用）
#    · **面积来自 .lib 的真实 area 字段**（与 LEF 的 SIZE 一致），所以
#      phys_SC9MC := 0，综合时跳过 read_physical（详见下方 phys_ 说明）。
#    综合路径已验证跑通（RC=0、WNS=0），是报告里"后端数字"的权威来源。
#
#  保留库：GPDK045（45nm 预测性教学库，Cadence 随 Innovus 发布）
#    · 三个角齐全，但 `.lib` 里所有单元 area 全是 0.0（演示库被剥掉面积字段），
#      面积只能从 LEF 的 SIZE 补（phys_GPDK045 := 1），且无 Verilog 模型，
#      做不了门级仿真。**仅作为早期快速迭代的备选**，不再用于正式报告。
#    注意：同一套单元还有个 gsclib045_v3.5（原始版，只有 slow 角），已弃用。
#
#  ⚠️ 两个必须知道的坑
#  1. **库的「面积来源」不同**（见下方 phys_ 段）：GPDK045 必须 read_physical
#     -lef 补面积，SC9MC 直接读 .lib。选错要么面积全 0、要么综合直接失败。
#  2. **电压不是 0.9V**。SC9MC 三角是 1.10 / 0.99 / 1.21 V；GPDK045 是
#     1.20 / 1.32 / 1.08 V。variants.mk 里曾写过的 tt_25C_0.90V 是占位符。
#     动态功耗 ∝ V²，标错电压会把功耗数字整体错一大截，必须按库填。
#
#  ── 换工艺时要改哪里 ──────────────────────────────────────────────
#  只需要在本文件加一段 `lib_<corner>_<PDK>` / `lef_<PDK>` / `pvt_<corner>_<PDK>`
#  / `phys_<PDK>` / `drive_<PDK>`，然后 `make syn PDK=<新库>`。
#  其余脚本一律不写库路径。
# =====================================================================

# ---- 工艺库选择 -------------------------------------------------------
PDK    ?= SC9MC
CORNER ?= tt
# CORNER: tt（典型，签核用）/ ff（最快，查 hold 与短路功耗）/ ss（最慢，查 setup）

# ---- GPDK045 ---------------------------------------------------------
GPDK045_DIR := /opt/cadence/INNOVUS152/share/FoundationFlows/EXAMPLES/INNOVUS/DESIGN/GPDK/LIBS/GPDK045

lib_tt_GPDK045 := $(GPDK045_DIR)/timing/typical.lib
lib_ff_GPDK045 := $(GPDK045_DIR)/timing/fast.lib
lib_ss_GPDK045 := $(GPDK045_DIR)/timing/slow.lib
lef_GPDK045    := $(GPDK045_DIR)/gsclib045.lef

# PVT 标签 = 报告与 EXPERIMENTS.md 里写的那个字符串，必须与 .lib 里的
# nom_process / nom_voltage / nom_temperature 一致（这是可核查的事实，不是自述）。
pvt_tt_GPDK045 := TT_25C_1V20
pvt_ff_GPDK045 := FF_0C_1V32
pvt_ss_GPDK045 := SS_125C_1V08

# ---- SMIC 40LL（真实商用工艺，sc9mc base RVT c40）---------------------
# 默认 PDK。与 GPDK045 的本质区别：这是可流片的真库。LEF 里带真实 SIZE，
# .lib 里 cell area 与 LEF 对得上（BUFH_X4M_A9TR40：1.52×1.26 = 1.9152 µm²，
# 两边一致），所以面积/延迟/功耗都对应真实工艺。GPDK045 是预测性 PDK，
# 数字不代表任何可制造的工艺 —— 只作为早期快速迭代的备选，正式报告用本库。
SC9MC_DIR := /opt/cadence/PDK/smic40/sc9mc_base_rvt_c40/r1p1

lib_tt_SC9MC := $(SC9MC_DIR)/lib/sc9mc_logic0040ll_base_rvt_c40_tt_typical_max_1p10v_25c.lib
lib_ss_SC9MC := $(SC9MC_DIR)/lib/sc9mc_logic0040ll_base_rvt_c40_ss_typical_max_0p99v_125c.lib
lib_ff_SC9MC := $(SC9MC_DIR)/lib/sc9mc_logic0040ll_base_rvt_c40_ff_typical_min_1p21v_m40c.lib
lef_SC9MC    := $(SC9MC_DIR)/lef/sc9mc_logic0040ll_base_rvt_c40.lef

# PVT 标签必须与 .lib 里的 nom_voltage / nom_temperature 一致（可核查的事实）
pvt_tt_SC9MC := TT_25C_1V10
pvt_ss_SC9MC := SS_125C_0V99
pvt_ff_SC9MC := FF_M40C_1V21

# 寄生提取：Innovus 用 qrcTechFile 做真实 RC 提取（每角一份）
qrc_tt_SC9MC := $(SC9MC_DIR)/voltagestorm/sc9mc_logic0040ll_base_rvt_c40_tt_typical_max_1p10v_25c.cl/qrcTechFile_RCgen
qrc_ss_SC9MC := $(SC9MC_DIR)/voltagestorm/sc9mc_logic0040ll_base_rvt_c40_ss_typical_max_0p99v_125c.cl/qrcTechFile_RCgen
qrc_ff_SC9MC := $(SC9MC_DIR)/voltagestorm/sc9mc_logic0040ll_base_rvt_c40_ff_typical_min_1p21v_m40c.cl/qrcTechFile_RCgen

# 门级仿真的单元行为模型（GPDK045 没有这份，所以那边做不了门级仿真）
verilog_SC9MC := $(SC9MC_DIR)/verilog/sc9mc_logic0040ll_base_rvt_c40.v

# 是否需要 read_physical -lef 来补面积。
#   GPDK045=1：它的 .lib 里 cell area 全为 0.0，面积只能从 LEF 的 SIZE 拿。
#   SC9MC=0  ：.lib 自带真实面积（BUFH_X4M_A9TR40 = 1.9152 µm²，与 LEF 的
#              1.52×1.26 一致），而它的 LEF 是 macro-only（LAYER 段为 0，
#              不带工艺层 RC），强行 read_physical 会报
#              "There is no capacitance, resistance specified [PHYS-10]"。
# 换 PDK 时先确认新库属于哪一类：选错要么面积全 0，要么综合直接失败。
phys_GPDK045 := 1
phys_SC9MC   := 0

# ---- 派生（下游一律用这三个变量，不要直接引用上面的长路径）------------
SYN_LIB  := $(lib_$(CORNER)_$(PDK))
SYN_LEF  := $(lef_$(PDK))
SYN_PHYS := $(phys_$(PDK))
PVT      := $(pvt_$(CORNER)_$(PDK))

# =====================================================================
#  综合约束参数
#
#  这几项直接决定面积和功耗数字，必须在三个方案之间完全一致，
#  并且原样写进报告（EXPERIMENTS.md 的「驱动负载 / 输入转换时间」一行）。
# =====================================================================

# 输入驱动单元：用库里的中速缓冲器，而不是 ideal 驱动。
# 用 ideal 会让输入转换时间为 0，路径延迟偏乐观，方案间差异也被抹平。
# ⚠ 单元名是库专属的：GPDK045 叫 BUFX4，SMIC40LL 叫 BUFH_X4M_A9TR40，
#   换 PDK 而忘了换这个，Genus 会直接报 "cell not found" 或者静默用 ideal drive。
drive_GPDK045 := BUFX4
drive_SC9MC   := BUFH_X4M_A9TR40
SYN_DRIVE_CELL ?= $(drive_$(PDK))

# 输出负载（pF）。16fF ≈ 一个扇出 2 的门 + 一小段线；综合阶段没有布线信息，
# 这个值只能声明+固定，不能"调到一个好看的数字"。
SYN_LOAD_PF    ?= 0.016

# 时钟不确定性（占周期的百分比）：吸收 PLL jitter + 布线偏斜。
# 综合阶段尚未布线，5% 是常见做法；数值写进报告，不许事后修改。
SYN_CLK_UNCERT_PCT ?= 5

# 输入/输出延迟（占周期的百分比）：粗略反映"外面还有一级寄存器"。
# 两侧合计 50%，留一半周期给组合逻辑，是保守但不至于不可实现的比例。
SYN_IO_DELAY_PCT   ?= 25

# 统计功耗用的翻转率假设。必须固定并声明，否则两次跑出来的 mW 不可比。
# toggle_rate 是"每个时钟周期翻转的概率"，0.1 = 数据类信号每 10 拍翻一次。
SYN_TOGGLE_RATE    ?= 0.1
SYN_STATIC_PROB    ?= 0.5
