# =====================================================================
#  flow/pnr/resume_route.tcl —— 从 CTS checkpoint 续跑布线 + 提取 + 时序
#
#  为什么单独一个脚本：
#    7 GB 的 VM 上，6 线程跑 detail routing 会被内核 OOM killer 杀掉
#    （退出码 137，日志停在 "start initial detail routing"）。
#    而一次 place + CTS 要 40 分钟，没必要为降线程数重做。
#    pnr.tcl 在 CTS 后存了 after_cts.enc，这里直接 saveRestore 续跑。
#
#  线程数：布线内存随线程数近似线性增长，2 线程实测峰值约 3 GB，安全。
#  代价是布线变慢，但比 OOM 重跑划算。
# =====================================================================
proc env {name} {
    if {![info exists ::env($name)]} { error "缺少环境变量 $name（必须由 run_resume.sh 导出）" }
    return $::env($name)
}

set outdir [env PNR_OUT]
set top    [env PNR_TOP]
set ckpt   "$outdir/after_cts.enc.dat"

puts "\[pnr\] 从 CTS checkpoint 续跑：$ckpt"
restoreDesign $ckpt $top

# 布线线程：内存敏感，2 线程
setMultiCpuUsage -localCpu 2
setNanoRouteMode -routeBottomRoutingLayer 2
# 提取精度：不设工艺节点时 Innovus 会用保守默认值（见 IMPEXT-3530 警告）
setDesignMode -process 40

puts "\n\[pnr\] ========== 5. Route（续跑） =========="
routeDesign
puts "\[pnr\] 布线完成"

puts "\n\[pnr\] ========== 6. 寄生提取 + 签核时序 =========="
setExtractRCMode -engine postRoute -effort high -coupled true
extractRC
timeDesign -postRoute -outDir $outdir/timing_postroute -numPaths 10
timeDesign -postRoute -hold -outDir $outdir/timing_postroute_hold -numPaths 10

puts "\n\[pnr\] ========== 7. 落盘 =========="
saveDesign $outdir/pnr.enc
write_netlist $outdir/pnr_netlist.v
defOut -floorplan -netlist -routing $outdir/pnr.def
summaryReport -outdir $outdir/summary

puts "\n\[pnr\] ========== DONE =========="
exit
