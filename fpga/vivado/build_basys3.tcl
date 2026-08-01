set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_dir [file join $repo_root build vivado_basys3]
file mkdir $build_dir

read_verilog -sv [file join $repo_root rtl systolic_pe.sv]
read_verilog -sv [file join $repo_root rtl systolic_array.sv]
read_verilog -sv [file join $repo_root fpga common systolicforge_fpga_demo.sv]
read_xdc [file join $repo_root fpga basys3 basys3.xdc]

synth_design -top systolicforge_fpga_demo -part xc7a35tcpg236-1
write_checkpoint -force [file join $build_dir post_synth.dcp]
report_utilization -file [file join $build_dir utilization_synth.rpt]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $build_dir post_route.dcp]
report_utilization -file [file join $build_dir utilization_route.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $build_dir timing_summary.rpt]
report_power -file [file join $build_dir power.rpt]
write_bitstream -force [file join $build_dir systolicforge_basys3.bit]
