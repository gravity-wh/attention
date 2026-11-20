# Analyze a mapped TT netlist with one gate-level VCD at its recorded frequency.
proc required {name} {
    if {![info exists ::env($name)] || $::env($name) eq ""} {
        error "Missing environment variable $name"
    }
    return $::env($name)
}

if {[catch {
    set out [required P4_OUT]
    file mkdir $out
    set init_top_cell [required P4_TOP]
    set init_verilog [required P4_NETLIST]
    set init_pwr_net VDD
    set init_gnd_net VSS
    set init_lef_file [list [required P4_TECH_LEF] [required P4_CELL_LEF]]

    set input [open [file join $out mmmc.tcl] w]
    puts $input [list create_library_set -name ls_tt -timing [list [required P4_LIBRARY]]]
    puts $input [list create_rc_corner -name rc_tt -T 25 -qx_tech_file [required P4_QRC]]
    puts $input [list create_delay_corner -name dc_tt -library_set ls_tt -rc_corner rc_tt]
    puts $input [list create_constraint_mode -name func -sdc_files [list [required P4_SDC]]]
    puts $input [list create_analysis_view -name view_tt -constraint_mode func -delay_corner dc_tt]
    puts $input [list set_analysis_view -setup view_tt -hold view_tt]
    close $input
    set init_mmmc_file [file join $out mmmc.tcl]
    init_design

    timeDesign -prePlace -outDir [file join $out timing] -numPaths 5
    set windows [open [required P4_WINDOWS] r]
    while {[gets $windows line] >= 0} {
        lassign [split $line "|"] sample waveform begin end
        if {$sample eq "" || ![file isfile $waveform]} {error "Invalid VCD window: $line"}
        read_activity_file -reset -format VCD -scope [required P4_SCOPE] \
            -start $begin -end $end $waveform
        report_power -view view_tt -power_unit mW -outfile [file join $out "$sample-power.rpt"]
    }
    close $windows
    puts "P4_POWER DONE"
} message]} {
    puts stderr "P4_POWER FAILED: $message"
    puts stderr $::errorInfo
    exit 1
}
exit 0
