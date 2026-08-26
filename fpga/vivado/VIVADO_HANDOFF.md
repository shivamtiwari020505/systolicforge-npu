# Vivado handoff: SystolicForge 8x8 INT8/INT32

## Read this first

There are two intentionally separate Vivado flows:

| Flow | Top module | Scope | Result type |
|---|---|---|---|
| Whole-NPU synthesis | `systolicforge_soc` | 8x8 array, instruction sequencer, scratchpads, and DMA | Out-of-context post-synthesis checkpoint and pre-place reports |
| Basys3 implementation | `systolicforge_fpga_uart_demo` | Compact 8x8 ISA engine, USB-UART loader, and shared-engine numerical self-test | Placed-and-routed checkpoint, reports, and board bitstream |

The Basys3 configuration contains an ISA-compatible instruction sequencer and
A/B/C scratchpads, but reduces them to 16 instruction words and 128 words per
scratchpad. The whole-NPU flow retains the default-depth SoC and DMA. Keep
those configuration-specific claims separate.

## Requirements

- Xilinx Vivado with support for the Artix-7 `xc7a35tcpg236-1` device.
- A complete copy of the repository, preserving its directory structure.
- A shell in which the `vivado` executable is available.
- A Digilent Basys3 only for the programming/test stage.

Run all commands from the repository root. Do not edit array or memory
parameters merely to make a failing build pass; return the failure log instead.

## Flow A: synthesize the complete NPU IP

This non-project flow synthesizes the complete default integration target:

- 8x8 physical systolic array;
- signed INT8 activations and weights;
- signed INT32 accumulation;
- instruction memory and sequencer;
- A/B/C scratchpads;
- burst DMA and external request/response interface.

On Windows Command Prompt or a Vivado-enabled shell:

```bat
mkdir build\vivado_npu_ooc
vivado -mode batch -source fpga/vivado/synth_npu_ooc.tcl -log build/vivado_npu_ooc/vivado.log -journal build/vivado_npu_ooc/vivado.jou
```

Expected artifacts:

```text
build/vivado_npu_ooc/build_manifest.txt
build/vivado_npu_ooc/post_synth_npu.dcp
build/vivado_npu_ooc/npu_post_synth.v
build/vivado_npu_ooc/npu_post_synth.xdc
build/vivado_npu_ooc/utilization_synth.rpt
build/vivado_npu_ooc/utilization_hierarchical_synth.rpt
build/vivado_npu_ooc/timing_summary_synth.rpt
build/vivado_npu_ooc/methodology_synth.rpt
build/vivado_npu_ooc/drc_synth.rpt
build/vivado_npu_ooc/vivado.log
build/vivado_npu_ooc/vivado.jou
```

Success criteria:

- Vivado exits with code zero.
- `synth_design` completes for `systolicforge_soc` without black boxes.
- The checkpoint and all reports exist and are non-empty.
- The hierarchical utilization report contains the array, NPU, and DMA
  hierarchy.
- Any inferred-memory warnings or large register/LUT structures are preserved
  for architectural review rather than hidden.

The timing report is a 10 ns out-of-context, post-synthesis estimate. It does
not include downstream I/O delays, placement, routing, or final SRAM bindings and
must not be presented as the product's achieved frequency.

## Flow B: implement the UART-programmable Basys3 demo

Target:

- Board: Digilent Basys3.
- FPGA: XC7A35T-1CPG236C.
- Top module: `systolicforge_fpga_uart_demo`.
- Clock constraint: 100 MHz.
- UART: 115200 8N1 through the board's USB-UART bridge.

Run:

```bat
mkdir build\vivado_basys3
vivado -mode batch -source fpga/vivado/build_basys3.tcl -log build/vivado_basys3/vivado.log -journal build/vivado_basys3/vivado.jou
```

The script performs synthesis, optimization, placement, physical optimization,
routing, timing analysis, vectorless power estimation, DRC/methodology reports,
checkpoint generation, timing-netlist/SDF generation, and bitstream generation.

Expected artifacts:

```text
build/vivado_basys3/build_manifest.txt
build/vivado_basys3/post_synth.dcp
build/vivado_basys3/post_synth.v
build/vivado_basys3/utilization_synth.rpt
build/vivado_basys3/utilization_hierarchical_synth.rpt
build/vivado_basys3/timing_summary_synth.rpt
build/vivado_basys3/post_route.dcp
build/vivado_basys3/post_route_timesim.v
build/vivado_basys3/post_route.sdf
build/vivado_basys3/route_status.rpt
build/vivado_basys3/utilization_route.rpt
build/vivado_basys3/utilization_hierarchical_route.rpt
build/vivado_basys3/timing_summary_route.rpt
build/vivado_basys3/clock_utilization.rpt
build/vivado_basys3/io.rpt
build/vivado_basys3/power_vectorless.rpt
build/vivado_basys3/methodology_route.rpt
build/vivado_basys3/drc_route.rpt
build/vivado_basys3/systolicforge_basys3.bit
build/vivado_basys3/vivado.log
build/vivado_basys3/vivado.jou
```

The script intentionally stops before bitstream generation if routed setup WNS
is negative. A successful board build requires:

- routing completed with no routing errors;
- non-negative routed setup WNS against the 10.000 ns clock;
- no DRC errors that block bitstream generation;
- a generated `.bit` file.

`power_vectorless.rpt` is a vectorless estimate unless switching activity is
later supplied. Label it accordingly in every published claim.

## Program and test the Basys3

1. Connect and power the Basys3.
2. Open Vivado Hardware Manager and connect to the target.
3. Program `build/vivado_basys3/systolicforge_basys3.bit`.
4. Press BTNU to reset.
5. Press BTNC once to start the self-test.
6. Confirm LED0 asserts without LED1.
7. Install `pyserial` and run the host-driven example on the enumerated serial
   port, for example:

```bat
python -m pip install pyserial
python scripts\systolicforge_uart_host.py --port COM5 ping
python scripts\systolicforge_uart_host.py --port COM5 run examples\matmul.json
```

LED meanings:

- LED0: completed and passed.
- LED1: self-test failed or execution-engine fault.
- LED2: compute or self-test busy.
- LED3: UART parser/response active.
- LED4: UART transmitter active.
- LED5: retained compute completion.
- LED6: UART framing-error sticky status.
- LED7: command-error sticky status.
- LEDs 11:8: execution-engine fault code.
- LEDs 15:12: execution-engine program counter.

The binary request/response contract and compact memory limits are documented
in `docs/UART_PROTOCOL.md`. Pressing BTNC overwrites program locations 0–1 and
A/B locations 0–63, so reload the UART workload after running the button test.

## Evidence package

Retain both complete build directories without deleting warnings or intermediate
reports:

```text
build/vivado_npu_ooc/
build/vivado_basys3/
```

Also retain:

- Vivado version and operating system;
- the exact source archive or Git commit used;
- a photo or short video showing LED0 asserted after the button test;
- the host utility log showing PING plus a full compiler/upload/result check;
- a note describing every critical warning or error;
- any manual changes made before or during either run.

These artifacts are required before publishing whole-NPU utilization or routed
FPGA timing, frequency, and power claims.
