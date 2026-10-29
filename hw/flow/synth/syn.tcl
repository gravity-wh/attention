# =====================================================================
#  flow/synth/syn.tcl —— Genus 综合脚本（一个方案的「一次综合」）
#
#  调用方：flow/synth/run_syn.sh（不要直接手敲 genus -f 这个文件）
#  所有参数从环境变量读，脚本本身不含任何绝对路径或魔数：
#    SYN_TOP / SYN_FLIST / SYN_OUT / SYN_CLK_NS / SYN_LIB / SYN_LEF
#    SYN_QB / SYN_QF / SYN_LUT          数值格式（必须与向量、仿真一致）
#    SYN_DRIVE_CELL / SYN_LOAD_PF / SYN_IO_DELAY_NS / SYN_CLK_UNCERT_NS
#    SYN_TOGGLE_RATE / SYN_STATIC_PROB
#
#  ── 三个设计决定 ──────────────────────────────────────────────────
# 1. **必须先 read_physical -lef**。GPDK045/gsclib045 的 .lib 里单元
#    area 全是 0.0（演示库被剥掉了面积字段）。不读 LEF 的话总面积报 0，
#    而 0 面积会一路混进报告表 2，表现为"面积改善无穷倍"。
# 2. **面积/时序/功耗三个数全部落成文件**，再由 run_syn.sh 统一解析。
#    不靠人眼抄屏幕，是"报告数字可追溯到原始报告"的前提。
# 3. **整个流程包在 proc 里 + catch**。不包的话，中途任何一句报错都会让
#    Genus 掉进交互模式（提示符 genus@root:>）而不返回 —— 在 runvm 这种
#    非交互调用里表现为"卡住"，比报错难查得多。见文件末尾的 catch。
#
#  ── 统计口径（报告里必须写明）───────────────────────────────────
#  面积 = 综合后网表的标准单元面积，**不含**布线开销、未插时钟树
#  时序 = 综合后静态时序分析，**不含**布线寄生
#  功耗 = 综合后基于固定活动率假设的静态估计，**不是**仿真功耗
# =====================================================================

proc require_env {name} {
    if {![info exists ::env($name)]} {
        error "缺少环境变量 $name —— 必须由 run_syn.sh 导出（不要直接跑这个脚本）"
    }
    return $::env($name)
}

proc main {} {
    set top   [require_env SYN_TOP]
    set flist [require_env SYN_FLIST]
    set out   [require_env SYN_OUT]
    set lib   [require_env SYN_LIB]
    set lef   [require_env SYN_LEF]
    set qb    [require_env SYN_QB]
    set qf    [require_env SYN_QF]
    set lut   [require_env SYN_LUT]
    set tog   [require_env SYN_TOGGLE_RATE]
    set sprob [require_env SYN_STATIC_PROB]

    file mkdir $out

    puts "\[syn\] top=$top  lib=$lib"
    puts "\[syn\] lef=$lef"
    puts "\[syn\] cfg=qb${qb}qf${qf} lut=$lut"

    # ------------------------------------------------------------ 库
    read_libs $lib

    # 面积来源：LEF。没有这一步，所有 cell 的 area 都是 0。
    read_physical -lef $lef

    # ------------------------------------------------------------ RTL
    # 数值格式的三个宏由 run_syn.sh 以 +define+ 写进 filelist.clean.f：
    # Genus 不允许 read_hdl 的 -define 与 -f 同时出现（HDL-12）。
    # 宏必须与仿真一致，否则 attn_pkg 的 Q_BITS/Q_FRAC 会退回默认值，
    # 综合出来的电路和验证过的不是同一个。
    read_hdl -sv -f $flist
    elaborate $top

    # ------------------------------------------------------------ 约束
    # 不允许工具自作主张插时钟门控：三个方案一旦一个插了一个没插，
    # 面积差里就混进了"优化选项差异"，单变量对照就不成立了。
    # 15.2 没有这个属性（TUI-183），所以包在 catch 里，改为事后查网表。
    if {[catch {set_db [get_db designs *] .lp_insert_clock_gating false} err]} {
        puts "\[syn\] NOTE 该版本不支持 lp_insert_clock_gating，跳过（结束前会检查网表里有无 ICG）"
    }
    read_sdc $out/constraints.sdc

    # ------------------------------------------------------------ 综合
    syn_generic
    syn_map
    syn_opt

    # ------------------------------------------------------------ 活动率
    # 功耗必须建立在明确的活动率假设上，否则两次跑的 mW 不可比。
    if {[catch {
        set_switching_activity -toggle_rate $tog -static_probability $sprob \
            [get_ports *]
        puts "\[syn\] 活动率已设置 toggle=$tog static=$sprob"
    } err]} {
        puts "\[syn\] WARN 活动率设置失败，功耗将用工具默认值：$err"
    }

    # ------------------------------------------------------------ 报告
    report_area   > $out/area.rpt
    report_timing -max_paths 1  -nworst 1  > $out/timing.rpt
    report_timing -max_paths 10 -nworst 10 > $out/timing_10.rpt
    report_power  > $out/power.rpt
    report_qor    > $out/qor.rpt

    # ------------------------------------------------------------ 产出
    write_hdl > $out/netlist.v
    write_sdc > $out/netlist.sdc

    # ------------------------------------------------------------ 指标
    # 用 get_attribute 直接取数，避免解析报告文本（格式随版本变）。
    # 每项单独 catch：某一项取不到不应让整次综合白跑，
    # 但会写成 MISSING，由 parse_syn.py 判定是否致命。
    set fh [open "$out/metrics.tcl" w]
    # 下面 foreach 的脚本串在花括号里，替换发生在 uplevel（全局作用域）时，
    # 所以必须把 top 放到全局，否则 $::top 取不到值。
    set ::top $top
    foreach {name script} {
        design_area   {get_attribute [get_designs $::top] area}
        cell_count    {llength [get_cells -hier *]}
        wns           {get_attribute [get_timing_paths -max_paths 1 -nworst 1 -path_group clk] slack}
        total_power   {get_attribute [get_designs $::top] total_power}
        leakage_power {get_attribute [get_designs $::top] leakage_power}
        num_regs      {llength [get_cells -hier -filter "is_sequential==true"]}
    } {
        if {[catch {uplevel #0 $script} v]} {
            puts $fh "$name MISSING"
            puts "\[syn\] WARN 取值失败 $name : $v"
        } else {
            puts $fh "$name $v"
        }
    }
    # 时钟门控自检：三个方案必须都没有 ICG，否则面积差里混进了
    # "是否插时钟门控"这个与算法无关的变量。（必须写在 close 之前）
    if {[catch {
        set icg [get_cells -hier * -filter "ref_name=~*ICG*"]
        puts $fh "icg_count [llength $icg]"
        puts "\[syn\] ICG 单元数 = [llength $icg]（应为 0）"
    } err]} {
        puts "\[syn\] NOTE ICG 检查跳过：$err"
    }

    close $fh

    puts "\[syn\] DONE"
}

# 出错就直接退出，绝不停在交互提示符上。
if {[catch {main} err]} {
    puts "\[syn\] FATAL: $err"
    puts "\[syn\] 见 $::env(SYN_OUT)/../syn.log 上方最后一条 ERROR"
    exit 1
}
exit 0
