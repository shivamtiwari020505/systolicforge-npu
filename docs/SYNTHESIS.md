# Synthesis results

These results were generated on 2026-07-30 under Ubuntu 24.04 in WSL 2 using
Yosys 0.33 (`2584903a060`). Generated logs and netlists live under `build/`,
which is intentionally ignored because they are reproducible artifacts.

## Generic 8×8 core

Command:

```sh
make synth
```

The design hierarchy contains 64 PEs: 56 regular partial-sum PEs and eight
top-row PEs. `check -assert` reported zero structural problems.

| Generic cell | Count |
|---|---:|
| Total cells | 38,519 |
| Enabled flip-flops (`$_DFFE_PN0P_`) | 2,432 |
| Flip-flops (`$_DFF_PN0_`) | 863 |
| NAND | 13,608 |
| XOR | 9,512 |
| AND | 6,600 |
| XNOR | 2,672 |
| OR | 1,520 |
| Other combinational cells | 1,312 |

This count is mapped to Yosys's generic gate library and is not a standard-cell
area number.

The synthesized netlist is also regression-tested:

```sh
make gate-sim
```

The 8×8 gate netlist passed all 48 signed matrix outputs, including an input
bubble. The primary artifacts are:

```text
build/yosys_synth.log
build/systolic_array_yosys.json
build/systolic_array_netlist.v
```

## Basys3 / Xilinx 7-series mapping

Command:

```sh
make synth-xc7
```

The complete `systolicforge_fpga_demo`, including the 8×8 array and on-chip
self-checker, maps to:

| Xilinx primitive | Count |
|---|---:|
| `DSP48E1` | 66 |
| `FDCE` | 3,338 |
| `CARRY4` | 63 |
| LUT2 | 77 |
| LUT3 | 10 |
| LUT4 | 5 |
| LUT5 | 52 |
| LUT6 | 122 |
| `MUXF7` | 69 |
| `MUXF8` | 29 |
| `BUFG` | 1 |

Each of the 64 PEs maps to one DSP48E1. The two additional DSPs implement
self-test comparison arithmetic and are not part of the compute array. The
Basys3 XC7A35T provides 90 DSP slices, making the complete mapping 73.3% of
available DSP resources.

`check -assert` reported zero problems. These are pre-place resource estimates;
the Vivado flow remains the authority for packed LUT/slice utilization, clock
frequency, routing, and power:

```sh
vivado -mode batch -source fpga/vivado/build_basys3.tcl
```

The Xilinx-mapped artifacts are:

```text
build/yosys_xc7_synth.log
build/systolicforge_basys3_yosys.json
build/systolicforge_basys3_netlist.v
```
