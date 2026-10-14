# SystolicForge NPU

[![CI](https://github.com/shivamtiwari020505/systolicforge-npu/actions/workflows/verify.yml/badge.svg)](https://github.com/shivamtiwari020505/systolicforge-npu/actions/workflows/verify.yml)
[![License: MIT](https://img.shields.io/github/license/shivamtiwari020505/systolicforge-npu)](LICENSE)

SystolicForge is an open, from-scratch INT8 matrix accelerator spanning RTL,
compiler, FPGA, and ASIC exploration flows. It combines a parameterized
weight-stationary systolic array with a programmable mini-NPU, burst DMA,
strided scratchpads, a host-facing AXI4-Lite control plane, and a
dependency-free MatMul compiler.

> **Active project focus:** SystolicForge is currently being completed as an
> academic and interview portfolio project. Work is prioritized around a
> reproducible end-to-end implementation, FPGA evidence, a board demonstration,
> and clear technical documentation. Commercial productization is not part of
> the active completion scope. See the
> [academic and interview project roadmap](docs/PROJECT_ROADMAP.md).

The default compute engine is **8×8**: 64 signed INT8 MACs operate every cycle
once the wavefront is full. `ROWS` and `COLS` are parameters, so the same RTL can
be elaborated as a 16×16 array when the target has enough resources.

| At a glance | Current implementation |
|---|---|
| Numeric path | Signed INT8 × INT8 with signed INT32 accumulation |
| Default compute | 8×8 array, 64 MAC/cycle |
| Peak datapath rate | 12.8 GOPS at 100 MHz, counting multiply and add separately (theoretical) |
| Programming model | 128-bit `NOP` / tiled `MATMUL` / `HALT` instruction stream |
| Host integration | 32-bit AXI4-Lite registers plus a Basys3 USB-UART loader and Python host utility |
| End-to-end path | JSON or optional ONNX → compiler images → self-checking RTL execution |
| Reproducible evidence | Icarus, Verilator, Yosys, and Graphviz exercised by CI |

**Project status:** the directed and randomized RTL regressions,
compiler-to-RTL flow, UART-programmable FPGA regression, lint, generic netlist
simulation, and Xilinx-7 resource mapping are reproducible and passing.
Archived Vivado 2025.2 evidence now includes full-NPU synthesis with eight BRAMs
and a +2.098 ns setup estimate, plus Basys3 100 MHz routed timing (+0.036 ns
setup, +0.067 ns hold) and a generated bitstream. Physical board validation and
Sky130 post-route PPA remain pending. See the
[October 14 evidence](docs/evidence/vivado/2026-10-14/README.md).

## Architecture at a glance

![SystolicForge system architecture](docs/diagrams/system_architecture.svg)

Every block in this diagram maps to committed RTL or compiler code. See the
[architecture and microarchitecture walkthrough](docs/ARCHITECTURE.md) for RTL
anchors, the PE-array dataflow, controller behavior, and simulation-derived
timing diagrams. The software-visible register contract is in the
[AXI4-Lite host-interface guide](docs/HOST_INTERFACE.md).

## What is implemented

- Signed INT8 × INT8 processing elements with signed 32-bit accumulation.
- Weight-stationary dataflow with activation skew, eastward activation
  propagation, and southward partial-sum propagation.
- A parameterized 8×8/16×16-capable array with one-cycle-per-row streaming.
- A 128-bit mini-NPU ISA with `NOP`, strided `MATMUL`, and `HALT`.
- A/B/C scratchpads, K-tile accumulation, an instruction sequencer, structured
  fault codes, and hardware bounds checks before memory side effects.
- A word-burst DMA with external valid/ready read and write channels.
- A 32-bit AXI4-Lite wrapper for program loading, DMA/compute commands,
  structured status, and interrupts.
- A dependency-free JSON compiler plus an optional ONNX frontend.
- A UART-programmable Basys3 execution-engine top, Python host utility, XDC,
  non-project Vivado build script, and retained button-driven self-test.
- OpenLane 2 and OpenROAD-flow-scripts configurations for Sky130.
- Self-checking RTL and compiler regressions suitable for CI.

## Verification status

The local regression currently passes:

| Test | Coverage | Result |
|---|---|---:|
| Systolic core | A=6x4 and B=4x4 on a physical 4x4 array; signed values, lane order, input bubble | PASS |
| Array arithmetic edges | Zero activations with nonzero weights; forced signed accumulator wrap in a 4x4/INT16 verification configuration | PASS |
| Memory redesign foundation | Full 4096-word synchronous SDP address range, registered-read hold, and read-first collision contract | PASS |
| Mini-NPU | A=3x6 and B=6x3 on a physical 4x4 array; K split 4+2, accumulation, strides | PASS |
| DMA | Five-word external→local and local→external bursts | PASS |
| Fault safety | Opcode, dimension, PC, scratchpad, DMA selector/range, no-op, and recovery cases | PASS |
| AXI4-Lite host path | Independent AW/W ordering, byte strobes, program/DMA/compute flow, errors, IRQs | PASS |
| Randomized differential | Seeded signed shapes, partial K/N tiles, accumulation, padded strides, boundary values, and memory stalls against Python | PASS |
| FPGA execution engine | Compiler-generated four-tile MATMUL plus HALT; all 60 C words checked | PASS |
| FPGA UART demo | Bit-level program/data upload, busy arbitration, signed execution, status/result readback, invalid request, and shared-engine 8×8 button self-test | PASS |
| Compiler | Encoding, M/K/N tiling, images, golden output, errors | PASS |
| Compiler → RTL | Generated five-word program and 60 golden outputs | PASS |
| Integrated SoC | DMA-loaded A/B through stalled external memory, compute arbitration, and DMA-stored 60-word C | PASS |
| Full-depth memory redesign | 4096/256 SoC; 32 legacy/golden comparisons, boundary/overflow/reset/read stalls; full SoC maps to 8 block RAMs (Yosys) | PASS |
| Generic synthesis | 64 PEs, structural check, synthesized-netlist simulation | PASS |
| Xilinx-7 mapping | UART/engine top: 72 DSP48E1, 56 distributed-RAM primitives, 2,677 LUT primitives, and 4,314 flip-flops (pre-place) | PASS |

The waveform figures are generated from Icarus VCD traces, and the block
diagrams are rendered from committed Graphviz sources. Their reproduction
commands and canonical signal-trace hashes are recorded in
[docs/diagrams/WAVEFORM_EVIDENCE.md](docs/diagrams/WAVEFORM_EVIDENCE.md).
The distinction between logical matrix dimensions and physical PE-array
dimensions, along with a signal-by-signal GTKWave explanation, is documented
in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#logical-matrices-versus-the-physical-pe-array).

Run everything on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_all_tests.ps1
```

Or on Linux/macOS with Icarus Verilog:

```sh
make test
```

Run or reproduce the randomized differential regression directly:

```sh
python scripts/run_randomized_differential.py --seed 0x5f2026d1 --cases 16
# Replay one failing case exactly:
python scripts/run_randomized_differential.py --seed <seed> --case-index <index>
```

Each case records its matrices, strided program, Python golden output, RTL log,
and seed under `build/randomized_differential/`. Failure artifacts are retained
and the harness prints the exact replay command. The harness uses the 4×4
verification configuration so compact test matrices frequently cross K/N tile
boundaries; the directed integrated-SoC and FPGA regressions retain coverage of
the default 8×8 configuration.

With Yosys installed:

```sh
make synth       # generic gate netlist and saved report
make gate-sim    # run the synthesized 8x8 netlist against the testbench
make synth-xc7   # Xilinx 7-series resource mapping for the Basys3 demo
```

To reproduce the complete evidence set with Icarus, Verilator, Yosys, and
Graphviz installed:

```sh
make evidence
```

The regression needs Python 3.10+ and Icarus Verilog. The JSON compiler and UART
client tests have no third-party Python dependency; physical serial-port access
uses optional `pyserial`.

## Compile a MatMul

```sh
python compiler/systolicforge_compile.py examples/matmul.json \
  -o build/example_program --array-rows 8 --array-cols 8
```

The compiler produces:

- `program.hex`: one 128-bit instruction per line, terminated by `HALT`;
- `a.hex` and `b.hex`: two's-complement INT8 scratchpad images;
- `c_expected.hex`: the signed INT32 golden result;
- `manifest.json`: dimensions, tile schedule, scales, and memory footprints.

For a single-MatMul ONNX model, install the optional `onnx` package and pass the
model path. B must be an initializer. If A is dynamic, provide its values with
`--a-data input.json`. Floating-point inputs are symmetrically quantized per
tensor and their scales are recorded in the manifest.

## FPGA and ASIC flows

For Basys3:

```sh
vivado -mode batch -source fpga/vivado/build_basys3.tcl
```

The generated bitstream runs a compact, ISA-compatible 8×8 execution engine
with a 115200-baud USB-UART loader. BTNU resets and BTNC runs the retained
self-test through the same engine. To compile, upload, execute, and compare the
example on a connected board:

```sh
python -m pip install pyserial
python scripts/systolicforge_uart_host.py --port COM5 run examples/matmul.json
```

The byte protocol and LED/status definitions are in
[docs/UART_PROTOCOL.md](docs/UART_PROTOCOL.md) and
[docs/FPGA.md](docs/FPGA.md). Reports and the bitstream land in
`build/vivado_basys3/`.

For Sky130 with OpenLane 2:

```sh
openlane pd/openlane/config.json
python scripts/collect_openlane_metrics.py <openlane-run-directory>
```

Generic and Xilinx-7 synthesis have been run with Yosys 0.33; the reproducible
results are recorded in [docs/SYNTHESIS.md](docs/SYNTHESIS.md). External Vivado
results for full-NPU synthesis and the routed Basys3 bitstream are archived.
They are not physical-board measurements; ASIC PPA remains unreported. The
supplied flows reproduce reports on machines with the corresponding tools.

## Repository map

```text
rtl/        PE, systolic array, mini-NPU, DMA, integrated SoC
tb/         self-checking SystemVerilog testbenches
compiler/   MatMul frontend, quantizer, tiler, encoder
include/    software-visible AXI4-Lite register definitions
examples/   example graph
fpga/       Basys3 wrapper, constraints, Vivado flow
pd/         Sky130 constraints and OpenLane/OpenROAD configs
synth/      generic Yosys synthesis script
docs/       architecture, ISA, FPGA, and physical-design notes
scripts/    Windows regressions and report extraction
tests/      Python compiler tests
```

The detailed design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), the
binary contract is in [docs/ISA.md](docs/ISA.md), and synthesis evidence is in
[docs/SYNTHESIS.md](docs/SYNTHESIS.md). Contributions are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md) for the verification and evidence policy.

The staged full-depth synchronous-memory migration and its acceptance gates are
defined in
[docs/MEMORY_ARCHITECTURE_REDESIGN.md](docs/MEMORY_ARCHITECTURE_REDESIGN.md).

The migration is implemented in the general NPU. It pipelines active weight
and A reads through synchronous RAM, overlaps A prefetch through two buffers,
and commits each row's C writes before issuing another row. The five-word
example takes 494 compute cycles after staged validation (prefetch-only version:
478; initial synchronous version: 1246); the array's
64-MAC/cycle capability remains a theoretical datapath peak. Reproduce the
full-depth comparisons and memory mapping with `make memory-redesign
synth-npu-full`. The October 13 Vivado full-profile run confirmed eight BRAMs
but failed its post-synthesis 100 MHz estimate. The October 14 correction run
passes that estimate; the compact Basys3 demo also meets routed timing and
generates a bitstream. See [FPGA_CLOSURE.md](docs/FPGA_CLOSURE.md).
