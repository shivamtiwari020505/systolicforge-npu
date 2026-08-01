# FPGA implementation

The Basys3 target uses the Artix-7 XC7A35T and the board's 100 MHz oscillator.
The wrapper intentionally keeps the 8×8 array internal; exposing all weights,
activations, and results as package pins would make place-and-route meaningless.

The demo stores a deterministic 8×8 activation matrix and signed diagonal weight
matrix in logic, streams eight rows through the array, and compares every output
inside the FPGA.

## Build

From the repository root:

```sh
vivado -mode batch -source fpga/vivado/build_basys3.tcl
```

The non-project script runs synthesis, optimization, placement, physical
optimization, routing, timing, power estimation, checkpoint creation, and
bitstream generation. Inspect:

```text
build/vivado_basys3/utilization_synth.rpt
build/vivado_basys3/utilization_route.rpt
build/vivado_basys3/timing_summary.rpt
build/vivado_basys3/power.rpt
build/vivado_basys3/systolicforge_basys3.bit
```

## Board behavior

- BTNU: asynchronous reset.
- BTNC: start or rerun the self-test.
- LED0: test completed and passed.
- LED1: test completed and failed.
- LED2: test is busy.
- LEDs 6:3: current input row.
- LEDs 14:7: raw array output-valid wavefront.

The two-stage start-button synchronizer handles metastability. It is not a
full mechanical debouncer, so one press can retrigger after completion if the
button bounces; that does not affect numerical correctness.

## Open-source resource estimate

`make synth-xc7` maps the complete self-test top to Xilinx 7-series primitives
with Yosys. The Yosys 0.33 run produced:

- 66 `DSP48E1` cells: 64 for the PEs and two for self-check arithmetic;
- 3,338 `FDCE` flip-flops;
- 63 `CARRY4` cells;
- 266 LUT2–LUT6 cells;
- zero structural-check errors.

The Basys3 XC7A35T contains 90 DSP slices, so the mapped design uses 73.3% of
that resource. This is a synthesis estimate, not a Vivado placed-and-routed
utilization or timing result.

Before programming a different Basys3 revision, compare
`fpga/basys3/basys3.xdc` against Digilent's master XDC for that board.
