# Vivado non-project-mode implementation for the UART-programmable Basys3 demo.
#
# Scope: 8x8 ISA-compatible FPGA engine, compact on-chip scratchpads, UART host
# bridge, and the retained button-driven numerical self-test. Use
# synth_npu_ooc.tcl for separate default-depth whole-SoC synthesis evidence.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set build_dir  [file join $repo_root build vivado_basys3]
set top_name   systolicforge_fpga_uart_demo
set part_name  xc7a35tcpg236-1

file mkdir $build_dir

set rtl_files [list \
    [file join $repo_root rtl systolic_pe.sv] \
    [file join $repo_root rtl systolic_array.sv] \
    [file join $repo_root fpga common systolicforge_fpga_engine.sv] \
    [file join $repo_root fpga common systolicforge_uart_rx.sv] \
    [file join $repo_root fpga common systolicforge_uart_tx.sv] \
    [file join $repo_root fpga common systolicforge_fpga_uart_demo.sv]]

foreach rtl_file $rtl_files {
    if {![file exists $rtl_file]} {
        error "Required RTL file not found: $rtl_file"
    }
    read_verilog -sv $rtl_file
}

set constraint_file [file join $repo_root fpga basys3 basys3.xdc]
if {![file exists $constraint_file]} {
    error "Required constraint file not found: $constraint_file"
}
read_xdc $constraint_file

puts "INFO: Implementing SystolicForge UART-programmable Basys3 demo"
puts "INFO: Top=$top_name Part=$part_name Configuration=8x8 INT8/INT32, 115200 baud"

synth_design \
    -top $top_name \
    -part $part_name \
    -flatten_hierarchy rebuilt

write_checkpoint -force [file join $build_dir post_synth.dcp]
write_verilog -force -mode funcsim [file join $build_dir post_synth.v]
report_utilization \
    -file [file join $build_dir utilization_synth.rpt]
report_utilization \
    -hierarchical \
    -hierarchical_depth 4 \
    -file [file join $build_dir utilization_hierarchical_synth.rpt]
report_timing_summary \
    -delay_type max \
    -max_paths 20 \
    -report_unconstrained \
    -check_timing_verbose \
    -file [file join $build_dir timing_summary_synth.rpt]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $build_dir post_route.dcp]
set sdf_file [file join $build_dir post_route.sdf]
write_sdf -force $sdf_file
write_verilog -force -mode timesim -sdf_anno true \
    -sdf_file $sdf_file \
    [file join $build_dir post_route_timesim.v]

report_route_status \
    -file [file join $build_dir route_status.rpt]
report_utilization \
    -file [file join $build_dir utilization_route.rpt]
report_utilization \
    -hierarchical \
    -hierarchical_depth 4 \
    -file [file join $build_dir utilization_hierarchical_route.rpt]
report_timing_summary \
    -delay_type min_max \
    -max_paths 20 \
    -report_unconstrained \
    -check_timing_verbose \
    -file [file join $build_dir timing_summary_route.rpt]
report_clock_utilization \
    -file [file join $build_dir clock_utilization.rpt]
report_io \
    -file [file join $build_dir io.rpt]
report_power \
    -file [file join $build_dir power_vectorless.rpt]
report_methodology \
    -file [file join $build_dir methodology_route.rpt]
report_drc \
    -file [file join $build_dir drc_route.rpt]

set worst_path [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
if {$worst_path eq ""} {
    error "No setup timing path was found after routing"
}
set route_wns [get_property SLACK $worst_path]

set manifest_path [file join $build_dir build_manifest.txt]
set manifest [open $manifest_path w]
puts $manifest "flow=basys3_uart_engine_implementation"
puts $manifest "top=$top_name"
puts $manifest "part=$part_name"
puts $manifest "board=Digilent_Basys3"
puts $manifest "array_rows=8"
puts $manifest "array_cols=8"
puts $manifest "data_width=8"
puts $manifest "accumulator_width=32"
puts $manifest "execution_engine=serialized_scratchpad_prefetch"
puts $manifest "scratchpad_words_per_memory=128"
puts $manifest "instruction_words=16"
puts $manifest "uart_format=115200_8N1"
puts $manifest "uart_clocks_per_bit=868"
puts $manifest "clock_period_ns=10.000"
puts $manifest "route_wns_ns=$route_wns"
puts $manifest "power_method=vectorless_estimate"
puts $manifest "vivado_version=[version -short]"
puts $manifest "generated_utc=[clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}]"

if {[catch {exec git -C $repo_root rev-parse HEAD} git_commit]} {
    set git_commit unknown
}
if {[catch {exec git -C $repo_root status --porcelain} git_status]} {
    set git_status unknown
} elseif {$git_status eq ""} {
    set git_status clean
} else {
    set git_status dirty
}
puts $manifest "git_commit=$git_commit"
puts $manifest "git_status=$git_status"
close $manifest

if {$route_wns < 0.0} {
    error "Routed design fails the 10.000 ns setup constraint: WNS=$route_wns ns"
}

write_bitstream -force [file join $build_dir systolicforge_basys3.bit]

puts "INFO: Basys3 implementation completed with routed WNS=$route_wns ns"
puts "INFO: Reports, checkpoint, and bitstream: $build_dir"
