# =====================================================================
#  flow/pnr/finish_pnr.tcl —— 从 pnr.enc 补跑提取 + 签核时序 + 落盘
#
#  为什么单独一个脚本：
#    首次跑完布线后，timeDesign -postRoute 报 IMPOPT-7027（要求 OCV 分析模式），
#    write_netlist 在 15.2 里不存在（应为 saveNetlist）。这两步失败不影响
#    已布好的版图，pnr.enc 已经存盘 —— 从它恢复补跑即可，不用重布线。
# =====================================================================
proc env {name} {
    if {![info exists ::env($name)]} { error "缺少环境变量 $name（必须由 run_finish.sh 导出）" }
    return $::env($name)
}

set outdir [env PNR_OUT]
set top    [env PNR_TOP]

puts "\[pnr\] 从已布线的 pnr.enc 恢复：$outdir/pnr.enc.dat"
restoreDesign $outdir/pnr.enc.dat $top

# 后布线时序必须是 OCV 模式，否则 timeDesign -postRoute 直接报错退出。
# cppr both：setup/hold 都做时钟重汇聚悲观度消除。
setAnalysisMode -analysisType onChipVariation -cppr both
setDesignMode -process 40

puts "\n\[pnr\] ========== 6. 寄生提取 + 后布线时序 =========="
setExtractRCMode -engine postRoute -effort medium -coupled true
extractRC
timeDesign -postRoute        -outDir $outdir/timing_postroute      -numPaths 10
timeDesign -postRoute -hold  -outDir $outdir/timing_postroute_hold -numPaths 10

puts "\n\[pnr\] ========== 7. 落盘 =========="
saveNetlist $outdir/pnr_netlist.v
defOut -floorplan -netlist -routing $outdir/pnr.def
report_area  > $outdir/area_final.rpt
reportPower > $outdir/power_final.rpt
summaryReport -outdir $outdir/summary

puts "\n\[pnr\] ========== DONE =========="
exit
