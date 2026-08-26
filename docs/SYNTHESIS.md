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

The mapping was rerun on 2026-08-26 for `systolicforge_fpga_uart_demo`. This top
contains the 8×8 array, compact ISA-compatible FPGA execution engine, 16-word
instruction memory, 128-word A/B/C scratchpads, UART RX/TX and command parser,
and the shared-engine button self-test. It maps to:

| Xilinx primitive | Count |
|---|---:|
| `DSP48E1` | 72 |
| `FDCE` | 3,733 |
| `FDRE` | 8,720 |
| `FDPE` | 5 |
| `CARRY4` | 114 |
| LUT1 | 349 |
| LUT2 | 1,475 |
| LUT3 | 867 |
| LUT4 | 870 |
| LUT5 | 473 |
| LUT6 | 3,987 |
| `MUXF7` | 3,178 |
| `MUXF8` | 1,226 |
| `BUFG` | 1 |

Each of the 64 PEs maps to one DSP48E1. Eight additional DSPs implement address
arithmetic and self-test checking; they are not extra MAC lanes. The Basys3
XC7A35T provides 90 DSP slices, so this mapping uses 80.0% of available DSPs.
The mapping contains 8,021 LUT1–LUT6 primitives and 12,458 flip-flops in total,
both below the device's raw logic capacity. Yosys implements the compact
scratchpads as registers and muxes in this run; serializing their compute-side
reads is what keeps that cost bounded.

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
