# Vivado non-project-mode synthesis for the complete SystolicForge NPU IP.
#
# Scope: systolicforge_soc with its default 8x8 INT8/INT32 configuration,
# instruction sequencer, A/B/C scratchpads, and DMA engine.
# This is out-of-context synthesis only; its timing numbers are pre-place and
# must not be presented as routed FPGA performance.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set build_dir  [file join $repo_root build vivado_npu_ooc]
set top_name   systolicforge_soc
set part_name  xc7a35tcpg236-1

file mkdir $build_dir

set rtl_files [list \
    [file join $repo_root rtl systolic_pe.sv] \
    [file join $repo_root rtl systolic_array.sv] \
    [file join $repo_root rtl systolicforge_npu.sv] \
    [file join $repo_root rtl scratchpad_dma.sv] \
    [file join $repo_root rtl systolicforge_soc.sv]]

foreach rtl_file $rtl_files {
    if {![file exists $rtl_file]} {
        error "Required RTL file not found: $rtl_file"
    }
    read_verilog -sv $rtl_file
}

set constraint_file [file join $script_dir npu_ooc.xdc]
if {![file exists $constraint_file]} {
    error "Required constraint file not found: $constraint_file"
}
read_xdc $constraint_file

puts "INFO: Synthesizing complete SystolicForge NPU"
puts "INFO: Top=$top_name Part=$part_name Configuration=8x8 INT8/INT32"

synth_design \
    -top $top_name \
    -part $part_name \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

write_checkpoint -force [file join $build_dir post_synth_npu.dcp]
write_verilog -force -mode funcsim [file join $build_dir npu_post_synth.v]
write_xdc -force [file join $build_dir npu_post_synth.xdc]

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
report_methodology \
    -file [file join $build_dir methodology_synth.rpt]
report_drc \
    -file [file join $build_dir drc_synth.rpt]

set manifest_path [file join $build_dir build_manifest.txt]
set manifest [open $manifest_path w]
puts $manifest "flow=whole_npu_out_of_context_synthesis"
puts $manifest "top=$top_name"
puts $manifest "part=$part_name"
puts $manifest "array_rows=8"
puts $manifest "array_cols=8"
puts $manifest "data_width=8"
puts $manifest "accumulator_width=32"
puts $manifest "clock_period_ns=10.000"
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

puts "INFO: Whole-NPU synthesis completed successfully"
puts "INFO: Reports and checkpoint: $build_dir"
