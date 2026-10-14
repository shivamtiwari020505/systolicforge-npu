# Vivado non-project-mode synthesis for the complete SystolicForge NPU IP.
#
# Scope: systolicforge_soc with an explicitly selected memory profile,
# 8x8 INT8/INT32 array, instruction sequencer, scratchpads, and DMA engine.
# This is out-of-context synthesis only; its timing numbers are pre-place and
# must not be presented as routed FPGA performance.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set top_name   systolicforge_soc
set part_name  xc7a35tcpg236-1

# Require explicit capacities in every archived result.
if {![info exists argv] || [llength $argv] != 1} {
    error "Select an OOC profile with -tclargs compact or -tclargs full. Compact uses 128 scratchpad words and 16 instructions; full uses 4096/256."
}
set profile [lindex $argv 0]
switch -- $profile {
    compact {
        set addr_w 7
        set imem_depth 16
    }
    full {
        set addr_w 12
        set imem_depth 256
    }
    default { error "Unknown OOC profile '$profile'; use compact or full" }
}
set scratchpad_words [expr {1 << $addr_w}]
set run_root [file join $repo_root build]
if {[info exists ::env(SYSTOLICFORGE_RUN_ROOT)]} {
    set run_root [file normalize $::env(SYSTOLICFORGE_RUN_ROOT)]
}
set build_dir [file join $run_root vivado_npu_ooc_$profile]
file mkdir $build_dir

set rtl_files [list \
    [file join $repo_root rtl systolic_pe.sv] \
    [file join $repo_root rtl systolic_array.sv] \
    [file join $repo_root rtl systolicforge_matmul_validator.sv] \
    [file join $repo_root rtl systolicforge_sdp_ram.sv] \
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
puts "INFO: Top=$top_name Part=$part_name Configuration=8x8 INT8/INT32 Profile=$profile"
puts "INFO: Scratchpad words per memory=$scratchpad_words Instruction words=$imem_depth"

# The scheduled engine uses synchronous SDP memories. Use normal inference;
# never bypass a failed inference by increasing the memory dissolve limit.
set dissolve_memory_size_limit_bits tool_default

# Record the selected configuration before synthesis so interrupted runs also
# retain their provenance. Completion is recorded only after all reports exist.
set manifest_path [file join $build_dir build_manifest.txt]
set manifest [open $manifest_path w]
puts $manifest "flow=whole_npu_out_of_context_synthesis"
puts $manifest "profile=$profile"
puts $manifest "top=$top_name"
puts $manifest "part=$part_name"
puts $manifest "array_rows=8"
puts $manifest "array_cols=8"
puts $manifest "data_width=8"
puts $manifest "accumulator_width=32"
puts $manifest "clock_period_ns=10.000"
puts $manifest "local_address_width=$addr_w"
puts $manifest "scratchpad_words_per_memory=$scratchpad_words"
puts $manifest "instruction_words=$imem_depth"
puts $manifest "execution_engine=scheduled_synchronous_sdp"
puts $manifest "operand_prefetch=pipelined_active_lanes"
puts $manifest "activation_row_buffers=2"
puts $manifest "instruction_validation=registered_8x16_product_25bit_range_check"
puts $manifest "row_addressing=incrementing_pointers"
puts $manifest "control_reset=synchronous_active_low"
puts $manifest "memory_mapping=inferred_block_ram"
puts $manifest "dissolve_memory_size_limit_bits=$dissolve_memory_size_limit_bits"
puts $manifest "fit_or_route_claim=none"
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

synth_design \
    -top $top_name \
    -part $part_name \
    -generic ARRAY_ROWS=8 \
    -generic ARRAY_COLS=8 \
    -generic ADDR_W=$addr_w \
    -generic IMEM_DEPTH=$imem_depth \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

write_checkpoint -force [file join $build_dir post_synth_npu.dcp]
write_verilog -force -mode funcsim [file join $build_dir npu_post_synth.v]
write_xdc -force [file join $build_dir npu_post_synth.xdc]

report_utilization -file [file join $build_dir utilization_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $build_dir utilization_hierarchical_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -report_unconstrained -check_timing_verbose \
    -file [file join $build_dir timing_summary_synth.rpt]
report_methodology -file [file join $build_dir methodology_synth.rpt]
report_drc -file [file join $build_dir drc_synth.rpt]

# A failed RAM inference is a failed run, even if synth_design itself returns.
set bram_cells [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set bram_count [llength $bram_cells]
if {$bram_count == 0} {
    error "No block RAM inferred for scheduled NPU storage; inspect synthesis warnings"
}
if {$profile eq "full" && $bram_count != 8} {
    error "Full-capacity storage expected 8 block RAM primitives, found $bram_count"
}
set worst_path [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
if {$worst_path eq ""} { error "No constrained setup path found after synthesis" }
set synth_wns [get_property SLACK $worst_path]

set manifest [open $manifest_path a]
puts $manifest "inferred_bram_primitives=$bram_count"
puts $manifest "synth_wns_ns=$synth_wns"
puts $manifest "synth_setup_target_met=[expr {$synth_wns >= 0.0}]"
puts $manifest "completed_utc=[clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}]"
close $manifest

puts "INFO: Whole-NPU $profile synthesis completed successfully"
if {$synth_wns < 0.0} {
    puts "WARNING: Post-synthesis 100 MHz setup estimate fails: WNS=$synth_wns ns. This is not timing closure."
}
puts "INFO: Reports and checkpoint: $build_dir"
