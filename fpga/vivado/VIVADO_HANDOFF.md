# Vivado handoff: SystolicForge 8×8 INT8 systolic array

## Target

- Board: Digilent Basys3
- FPGA: XC7A35T-1CPG236C
- Top module: `systolicforge_fpga_demo`
- Clock: 100 MHz

The top contains the full 8×8 INT8 systolic array and an on-chip numerical
self-test. No external data connection is required.

## Build

Open a Vivado Tcl Shell, change into the extracted repository root, and run:

```tcl
vivado -mode batch -source fpga/vivado/build_basys3.tcl
```

The script performs synthesis, optimization, placement, physical optimization,
routing, timing analysis, power estimation, checkpoint generation, and
bitstream generation.

Expected artifacts:

```text
build/vivado_basys3/post_synth.dcp
build/vivado_basys3/post_route.dcp
build/vivado_basys3/utilization_synth.rpt
build/vivado_basys3/utilization_route.rpt
build/vivado_basys3/timing_summary.rpt
build/vivado_basys3/power.rpt
build/vivado_basys3/systolicforge_basys3.bit
```

The build is successful only if routing completes and the timing report shows
non-negative setup WNS. Do not treat synthesis-only estimates as final
utilization or timing.

## Program and test

1. Connect and power the Basys3.
2. Open Vivado Hardware Manager and connect to the target.
3. Program `build/vivado_basys3/systolicforge_basys3.bit`.
4. Press BTNU to reset.
5. Press BTNC once to start the self-test.

LED meanings:

- LED0: completed and passed.
- LED1: completed and failed.
- LED2: busy.
- LEDs 6:3: current input row.
- LEDs 14:7: array output-valid wavefront.

## Return for project evidence

Please return:

- the complete `build/vivado_basys3/` directory;
- the Vivado version and operating system;
- a photo or short video showing LED0 asserted after the test;
- any critical warnings from the batch log.

The reports and tool version are needed before publishing FPGA utilization,
frequency, or power claims.
