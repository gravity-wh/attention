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
set util     [expr {[info exists ::env(PNR_UTIL)] ? $::env(PNR_UTIL) : 0.65}]

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
