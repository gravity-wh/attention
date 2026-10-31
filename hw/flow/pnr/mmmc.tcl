# =====================================================================
#  flow/pnr/mmmc.tcl —— Innovus 多角多模分析视图
#
#  由 flow/pnr/run_pnr.sh 通过环境变量注入所有路径，本文件不含任何
#  绝对路径或魔数（与 syn.tcl 同一套约定）。
#
#  三个角取自 SMIC40 的 5 个 .lib（tt/ss/ff 各取一个）：
#    tt : 1.10 V /  25 ℃   —— 典型，看面积功耗
#    ss : 0.99 V / 125 ℃  —— 最慢，签核 setup
#    ff : 1.21 V / -40 ℃  —— 最快，签核 hold
#  每个角配一份 qrcTechFile_RCgen，供 route 后真实寄生提取。
#
#  注意：SDC 来自 Genus 的 netlist.sdc，里面已含 create_clock 与 IO 约束，
#  所以这里只建 constraint_mode 引用它，不重复写时序约束 —— 两处都写迟早
#  会不一致，而那种不一致在时序报告里表现为"明明改了约束却没生效"。
# =====================================================================

proc env {name} {
    if {![info exists ::env($name)]} {
        error "缺少环境变量 $name —— 必须由 run_pnr.sh 导出"
    }
    return $::env($name)
}

set lib_tt [env PNR_LIB_TT]
set lib_ss [env PNR_LIB_SS]
set lib_ff [env PNR_LIB_FF]
set qrc_tt [env PNR_QRC_TT]
set qrc_ss [env PNR_QRC_SS]
set qrc_ff [env PNR_QRC_FF]
set sdc    [env PNR_SDC]

puts "\[pnr\] MMMC: tt=$lib_tt"
puts "\[pnr\] MMMC: ss=$lib_ss"
puts "\[pnr\] MMMC: ff=$lib_ff"

create_library_set -name ls_tt -timing [list $lib_tt]
create_library_set -name ls_ss -timing [list $lib_ss]
create_library_set -name ls_ff -timing [list $lib_ff]

create_rc_corner -name rc_tt -T 25  -qx_tech_file $qrc_tt
create_rc_corner -name rc_ss -T 125 -qx_tech_file $qrc_ss
create_rc_corner -name rc_ff -T -40 -qx_tech_file $qrc_ff

create_delay_corner -name dc_tt -library_set ls_tt -rc_corner rc_tt
create_delay_corner -name dc_ss -library_set ls_ss -rc_corner rc_ss
create_delay_corner -name dc_ff -library_set ls_ff -rc_corner rc_ff

create_constraint_mode -name func -sdc_files [list $sdc]

create_analysis_view -name view_tt -constraint_mode func -delay_corner dc_tt
create_analysis_view -name view_ss -constraint_mode func -delay_corner dc_ss
create_analysis_view -name view_ff -constraint_mode func -delay_corner dc_ff

# setup 用最慢角，hold 用最快角；tt 只用于面积/功耗观察
set_analysis_view -setup {view_ss} -hold {view_ff}
