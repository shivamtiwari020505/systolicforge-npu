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

The mapping was rerun on 2026-09-16 for `systolicforge_fpga_uart_demo`. This top
contains the 8×8 array, compact ISA-compatible FPGA execution engine, 16-word
instruction memory, 128-word A/B/C scratchpads, UART RX/TX and command parser,
and the shared-engine button self-test. It maps to:

| Xilinx primitive | Count |
|---|---:|
| `DSP48E1` | 72 |
| `FDCE` | 3,733 |
| `FDRE` | 576 |
| `FDPE` | 5 |
| `CARRY4` | 114 |
| LUT1 | 80 |
| LUT2 | 791 |
| LUT3 | 411 |
| LUT4 | 229 |
| LUT5 | 373 |
| LUT6 | 793 |
| `MUXF7` | 473 |
| `MUXF8` | 123 |
| `RAM32M` | 22 |
| `RAM64M` | 34 |
| `BUFG` | 1 |

Each of the 64 PEs maps to one DSP48E1. Eight additional DSPs implement address
arithmetic and self-test checking; they are not extra MAC lanes. The Basys3
XC7A35T provides 90 DSP slices, so this mapping uses 80.0% of available DSPs.
The mapping contains 2,677 LUT1–LUT6 primitives and 4,314 flip-flops in total,
plus 56 distributed-RAM primitives. The compact scratchpads use asynchronous
reads and reset-free synchronous write ports so they map to FPGA memory instead
of a register bank and deep write mux.

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

## Full-depth synchronous-memory foundation

The proposed general-NPU storage foundation is checked independently from the
existing NPU controller:

```sh
make memory-foundation memory-foundation-synth
```

The 2026-10-12 Yosys 0.33 Xilinx-7 smoke run contains the default 4096-word A,
B, and C scratchpads plus the 256x128-bit instruction memory. It maps to eight
`RAMB36E1` primitives (A: 1, B: 1, C: 4, instruction memory: 2) and
`check -assert` reports zero structural problems. The synthesis script asserts
the eight-block count.

This result validates the synchronous SDP storage coding style and capacity
only. The smoke harness is not the NPU controller, and these numbers are not a
complete-NPU utilization, timing, routing, or bitstream result. The integration
and acceptance plan is in
[MEMORY_ARCHITECTURE_REDESIGN.md](MEMORY_ARCHITECTURE_REDESIGN.md).

## Full default NPU/SoC mapping after memory correction

Run `make synth-npu-full`. On 2026-10-13, Yosys 0.33 mapped the complete
`systolicforge_soc` (8x8, 4096 words per scratchpad, 256 instructions) to:

| Primitive group | Count |
|---|---:|
| RAMB36E1 | 8 |
| DSP48E1 | 73 |
| LUT1-LUT6 primitives | 1213 |
| Flip-flops (FDCE + FDRE) | 4074 |
| CARRY4 | 117 |
| MUXF7 / MUXF8 | 202 / 60 |

These counts describe the initial synchronous design at `f56b35c`. The
subsequent pipelined-prefetch version maps to eight RAMB36E1, 73 DSP48E1,
1943 LUT primitives, 4046 flip-flops, 12 RAM32M, 143 CARRY4, 107 MUXF7 and
33 MUXF8. Bulk-memory capacities remain unchanged; distributed RAM is used
for small tile storage. The full-depth synthesis assertion still passes.

The flattened design passes `check -assert` and an exact eight-BRAM assertion.
Generated artifacts are `build/yosys_npu_full.log`,
`build/systolicforge_soc_full_xc7.json`, and
`build/systolicforge_soc_full_xc7.v`. The nine DSPs beyond the 64 PEs implement
address/bounds arithmetic. Yosys primitive-port resizing warnings are retained
in the log; structural checks report zero problems.

These are pre-place estimates for the entire general SoC, separate from the
Basys3 UART demonstration. Vivado confirmation remains pending. The OOC flow
uses `-tclargs full`, includes the RAM primitive, and no longer changes the
memory-dissolve limit.
