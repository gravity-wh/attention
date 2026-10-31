# =====================================================================
#  flow/pnr/pnr.tcl —— Innovus 全流程（floorplan -> place -> CTS -> route）
#
#  由 flow/pnr/run_pnr.sh 调用，所有路径经环境变量注入。
#  输入是 Genus 综合后的门级网表 + 它自己导出的 netlist.sdc，
#  所以"综合和 P&R 用的是同一份约束"这件事由文件传递保证，不靠人抄。
#
#  统计口径（写报告时必须带上）：
#    面积 = 布局布线后实际占用的单元面积 + 布线拥塞导致的空白
#    时序 = 真实 RC 提取（qrcTechFile）后的 STA，不是综合阶段的线负载估计
#    功耗 = 仍需 postRoute + SAIF/VCD 才准确，本流程只报工具默认活动率
# =====================================================================

proc env {name} {
    if {![info exists ::env($name)]} { error "缺少环境变量 $name（必须由 run_pnr.sh 导出）" }
    return $::env($name)
}
proc step {msg} { puts "\n\[pnr\] ========== $msg ==========" }

set tech_lef [env PNR_TECH_LEF]
set cell_lef [env PNR_CELL_LEF]
set netlist  [env PNR_NETLIST]
set top      [env PNR_TOP]
set outdir   [env PNR_OUT]
set util     [expr {[info exists ::env(PNR_UTIL)] ? $::env(PNR_UTIL) : 0.55}]

file mkdir $outdir

step "0. 初始化（tech LEF 必须在单元 LEF 前面）"
set init_lef_file [list $tech_lef $cell_lef]
set init_verilog  $netlist
set init_top_cell $top
set init_mmmc_file [env PNR_MMMC]
set init_pwr_net  VDD
set init_gnd_net  VSS
init_design
puts "\[pnr\] 单元数 = [llength [dbGet -e top.insts.name]]"

# M1 只放单元内部的电源轨/引脚，信号布线从 M2 起。
# 原因：由 techfile.tf 生成的 tech LEF 里 M1 间距规则与单元实际几何不一致，
# 一旦允许 NanoRoute 用 M1，CTS 阶段就会出现 8 万+ 条 M1 间距违例且不收敛。
# 禁用 M1 信号布线后违例降到可收敛范围；代价是布线资源变少，面积/时序略差，
# 报告里必须注明"信号层从 M2 起"。
# 多线程：不设的话 NanoRoute 默认单线程，69k 单元的 detail routing 会跑数小时。
# 本机 8 核 / 7 GB，取 6 线程（留出内存余量，布线内存约 2–3 GB/线程峰值）。
setMultiCpuUsage -localCpu 6

setNanoRouteMode -routeBottomRoutingLayer 2

step "1. 电源网络"
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

step "2. Floorplan（利用率 $util）"
floorPlan -r 1.0 $util 5 5 5 5
addRing -nets {VDD VSS} -type core_rings -follow core \
        -layer {top M5 bottom M5 left M4 right M4} \
        -width 1.2 -spacing 0.6 -offset 1.5
addStripe -nets {VDD VSS} -layer M4 -direction vertical \
          -width 0.6 -spacing 0.6 -set_to_set_distance 25
addStripe -nets {VDD VSS} -layer M5 -direction horizontal \
          -width 0.6 -spacing 0.6 -set_to_set_distance 25
sroute -connect {corePin} -layerChangeRange {M1 M5} -allowJogging 1
puts "\[pnr\] floorplan 完成"

step "3. Place"
placeDesign
puts "\[pnr\] placement 完成"

step "4. CTS（单时钟，ccopt）"
ccopt_design
puts "\[pnr\] CTS 完成"
# CTS 后立即存盘：布线可能跑很久甚至失败，有这个点就能 saveRestore 续跑，
# 不用重做 place/CTS（单次 CTS 在本机约 40 分钟）。
saveDesign $outdir/after_cts.enc

step "5. Route"
routeDesign
puts "\[pnr\] 布线完成"

# 布线后必须重连 PG 到 std cell（route 会断开部分连接的情况）
sroute -connect {corePin} -layerChangeRange {M1 M5}

step "6. 寄生提取 + 签核时序"
setExtractRCMode -engine postRoute -effort high -coupled true
extractRC
timeDesign -postRoute -outDir $outdir/timing_postroute -numPaths 10
timeDesign -postRoute -hold -outDir $outdir/timing_postroute_hold -numPaths 10

step "7. 落盘"
saveDesign $outdir/pnr.enc
write_netlist $outdir/pnr_netlist.v
defOut -floorplan -netlist -routing $outdir/pnr.def
summaryReport -outdir $outdir/summary

puts "\n\[pnr\] ========== DONE =========="
exit
