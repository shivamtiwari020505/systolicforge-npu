# SystolicForge NPU

[![CI](https://github.com/shivamtiwari020505/systolicforge-npu/actions/workflows/verify.yml/badge.svg)](https://github.com/shivamtiwari020505/systolicforge-npu/actions/workflows/verify.yml)
[![License: MIT](https://img.shields.io/github/license/shivamtiwari020505/systolicforge-npu)](LICENSE)

SystolicForge is an open, from-scratch INT8 matrix accelerator spanning RTL,
compiler, FPGA, and ASIC exploration flows. It combines a parameterized
weight-stationary systolic array with a programmable mini-NPU, burst DMA,
strided scratchpads, a host-facing AXI4-Lite control plane, and a
dependency-free MatMul compiler.

The default compute engine is **8×8**: 64 signed INT8 MACs operate every cycle
once the wavefront is full. `ROWS` and `COLS` are parameters, so the same RTL can
be elaborated as a 16×16 array when the target has enough resources.

| At a glance | Current implementation |
|---|---|
| Numeric path | Signed INT8 × INT8 with signed INT32 accumulation |
| Default compute | 8×8 array, 64 MAC/cycle |
| Peak datapath rate | 12.8 GOPS at 100 MHz, counting multiply and add separately (theoretical) |
| Programming model | 128-bit `NOP` / tiled `MATMUL` / `HALT` instruction stream |
| Host integration | 32-bit AXI4-Lite registers, command error responses, sticky interrupt status |
| End-to-end path | JSON or optional ONNX → compiler images → self-checking RTL execution |
| Reproducible evidence | Icarus, Verilator, Yosys, and Graphviz exercised by CI |

**Project status:** the RTL regressions, compiler-to-RTL flow, lint, generic
netlist simulation, and Xilinx-7 resource mapping are reproducible and passing.
Routed Basys3 timing/bitstream evidence and Sky130 post-route PPA remain external
tool milestones, so this repository does not claim those results yet.

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
- A Basys3 self-test top, XDC, and non-project Vivado build script.
- OpenLane 2 and OpenROAD-flow-scripts configurations for Sky130.
- Self-checking RTL and compiler regressions suitable for CI.

## Verification status

The local regression currently passes:

| Test | Coverage | Result |
|---|---|---:|
| Systolic core | A=6x4 and B=4x4 on a physical 4x4 array; signed values, lane order, input bubble | PASS |
| Mini-NPU | A=3x6 and B=6x3 on a physical 4x4 array; K split 4+2, accumulation, strides | PASS |
| DMA | Five-word external→local and local→external bursts | PASS |
| Fault safety | Opcode, dimension, PC, scratchpad, DMA selector/range, no-op, and recovery cases | PASS |
| AXI4-Lite host path | Independent AW/W ordering, byte strobes, program/DMA/compute flow, errors, IRQs | PASS |
| FPGA demo | Complete on-chip 8×8 self-test | PASS |
| Compiler | Encoding, M/K/N tiling, images, golden output, errors | PASS |
| Compiler → RTL | Generated five-word program and 60 golden outputs | PASS |
| Integrated SoC | DMA-loaded A/B through stalled external memory, compute arbitration, and DMA-stored 60-word C | PASS |
| Generic synthesis | 64 PEs, structural check, synthesized-netlist simulation | PASS |
| Xilinx-7 mapping | 64 array DSPs; 66 DSP48E1 cells including self-test | PASS |

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

The regression needs Python 3.10+ and Icarus Verilog. The JSON compiler has no
third-party Python dependency.

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

The generated bitstream runs an on-chip signed-matmul self-test. BTNU resets,
BTNC starts, LED0 means pass, LED1 means fail, and LED2 means busy. Reports and
the bitstream land in `build/vivado_basys3/`.

For Sky130 with OpenLane 2:

```sh
openlane pd/openlane/config.json
python scripts/collect_openlane_metrics.py <openlane-run-directory>
```

Generic and Xilinx-7 synthesis have been run with Yosys 0.33; the reproducible
results are recorded in [docs/SYNTHESIS.md](docs/SYNTHESIS.md). Vivado,
OpenLane/OpenROAD, and a Sky130 PDK are not installed, so post-route FPGA timing
and ASIC PPA numbers are deliberately not claimed yet. The supplied flows
generate those reports on a machine with the corresponding tools installed.

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
