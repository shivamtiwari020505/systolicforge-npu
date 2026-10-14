# Vivado handoff: SystolicForge 8x8 INT8/INT32

## Read this first

There are two intentionally separate Vivado flows:

| Flow | Top module | Scope | Result type |
|---|---|---|---|
| Full whole-NPU synthesis | `systolicforge_soc` | 8x8 array, general NPU, DMA, 4096 words per scratchpad, 256 instructions | Out-of-context post-synthesis checkpoint and pre-place reports for this configuration only |
| Basys3 implementation | `systolicforge_fpga_uart_demo` | Compact 8x8 ISA engine, USB-UART loader, and shared-engine numerical self-test | Placed-and-routed checkpoint, reports, and board bitstream |

The Basys3 configuration contains an ISA-compatible instruction sequencer and
A/B/C scratchpads, but reduces them to 16 instruction words and 128 words per
scratchpad. The compact OOC profile has the same capacities but retains the
general NPU and DMA, using synchronous block RAM and scheduled accesses. The
Basys3 engine uses distributed RAM and a separate schedule. Keep their results separate.

Run the Basys3 implementation first. It is independent of the OOC flow and
does not need its checkpoint. Neither profile has a guaranteed run time or
timing result until its Vivado reports are available.

## Requirements

The preferred Windows launcher is now:

```bat
fpga\vivado\run_vivado.cmd all
```

It runs each flow independently in a fresh timestamped directory under
`build/vivado_runs/`, creates log directories before Vivado starts, records
source SHA-256 hashes even without Git, and packages complete results including
failure logs. Use `full` or `basys3` instead of `all` for an individual run.
See [FPGA_RERUN.md](../../FPGA_RERUN.md) for the current closure handoff.

- Xilinx Vivado with support for the Artix-7 `xc7a35tcpg236-1` device.
- A complete copy of the repository, preserving its directory structure.
- A shell in which the `vivado` executable is available.
- A Digilent Basys3 only for the programming/test stage.

Run all commands from the repository root in a fresh extraction. Select the
documented OOC profile explicitly; preserve its parameters in any published
results. Return failure logs without making undocumented parameter changes.

## Flow A: synthesize the complete NPU IP

This non-project flow synthesizes all integration blocks with explicitly
selected memory capacities:

- 8x8 physical systolic array;
- signed INT8 activations and weights;
- signed INT32 accumulation;
- instruction memory and sequencer;
- A/B/C scratchpads;
- burst DMA and external request/response interface.

The general NPU now uses scheduled synchronous SDP storage. Select `full` for
the next run: 4096 words per A/B/C scratchpad, 256 instructions, an 8x8 array
and DMA. The instruction encoding and host registers are unchanged. Execution
latency increases because each row finishes C writeback before the next starts.

The current version pipelines active-lane reads and overlaps A prefetch using
two activation buffers. The compiler example takes 478 compute cycles locally,
versus 1246 for the initial synchronous design. The build manifest records the
prefetch mode and buffer count. Full-NPU routed frequency remains unvalidated;
the separate compact Basys3 run now has archived 100 MHz routed evidence.

The interrupted 2026-10-12 run used behavioral multi-port arrays. That engine
is retained only in `tb/reference/` for simulation comparisons. The current
synthesis sources include the synchronous RAM primitive and use normal memory
inference without a dissolve-limit override.

Complete default SoC Yosys mapping passes structural checks and the eight-BRAM
assertion. Simulation includes the full 4096/256 compiler-DMA-SoC test and 32
legacy/golden comparisons. The October 13 full-profile Vivado run confirmed
eight BRAMs but its estimated WNS was -7.392 ns. Staged validation, incrementing
row pointers and synchronous control resets passed the October 14 full-profile
setup estimate (+2.098 ns), with eight BRAMs. The compact Basys3 run separately
meets routed timing and generates a bitstream. The example takes 494 compute
cycles. See [the archives](../../docs/evidence/vivado/2026-10-14/README.md).

The optional `compact` profile selects 128 words per scratchpad and 16
instructions through the same scheduled engine. Archive capacities separately.
An omitted profile stops before synthesis.

On Windows Command Prompt or a Vivado-enabled shell:

```bat
mkdir build\vivado_npu_ooc_full
vivado -mode batch -source fpga/vivado/synth_npu_ooc.tcl -log build/vivado_npu_ooc_full/vivado.log -journal build/vivado_npu_ooc_full/vivado.jou -tclargs full
```

Expected artifacts:

```text
build/vivado_npu_ooc_full/build_manifest.txt
build/vivado_npu_ooc_full/post_synth_npu.dcp
build/vivado_npu_ooc_full/npu_post_synth.v
build/vivado_npu_ooc_full/npu_post_synth.xdc
build/vivado_npu_ooc_full/utilization_synth.rpt
build/vivado_npu_ooc_full/utilization_hierarchical_synth.rpt
build/vivado_npu_ooc_full/timing_summary_synth.rpt
build/vivado_npu_ooc_full/methodology_synth.rpt
build/vivado_npu_ooc_full/drc_synth.rpt
build/vivado_npu_ooc_full/vivado.log
build/vivado_npu_ooc_full/vivado.jou
```

Success criteria:

- Vivado exits with code zero.
- The manifest records `profile=full`, `scratchpad_words_per_memory=4096`,
  `instruction_words=256`, and `completed_utc`. Configuration is recorded before
  synthesis so aborted runs retain provenance; completion requires all reports.
- `synth_design` completes for `systolicforge_soc` without black boxes.
- The checkpoint and all reports exist and are non-empty.
- The hierarchical utilization report contains the array, NPU, and DMA
  hierarchy.
- Any inferred-memory warnings or large register/LUT structures are preserved
  for architectural review rather than hidden.
- Capacity overuse, if reported, is recorded as a limitation rather than
  presented as a successful Basys3 implementation.

The timing report is a 10 ns out-of-context, post-synthesis estimate. It does
not include downstream I/O delays, placement, routing, or final SRAM bindings and
must not be presented as the product's achieved frequency.

The script checks that block RAM was inferred and records its count before
marking the run complete. Preserve warnings and hierarchical reports for
review. No memory-dissolve-limit override is enabled.

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
- non-negative routed hold slack;
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
build/vivado_npu_ooc_full/
build/vivado_basys3/
```

Also retain:

- Vivado version and operating system;
- the exact source archive or Git commit used;
- the OOC profile and memory capacities; retain the interrupted full-depth
  logs separately if available;
- a photo or short video showing LED0 asserted after the button test;
- the host utility log showing PING plus a full compiler/upload/result check;
- a note describing every critical warning or error;
- any manual changes made before or during either run.

These artifacts are required before publishing whole-NPU utilization or routed
FPGA timing, frequency, and power claims.
