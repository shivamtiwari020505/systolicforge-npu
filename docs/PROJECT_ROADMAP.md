# SystolicForge NPU academic and interview roadmap

> **Active project plan:** Complete SystolicForge as a rigorous academic project
> and interview-ready engineering portfolio. Commercial productization,
> licensing strategy, and production qualification are not part of this plan.

## Completion target

The project is complete for its current purpose when it has:

- a reproducible compiler-to-RTL matrix-multiplication path;
- self-checking verification for the core, NPU, DMA, faults, SoC, and host path;
- documented architecture, ISA, register interface, limitations, and results;
- defensible synthesis and FPGA implementation evidence;
- a repeatable Basys3 demonstration when board access is available; and
- a concise final report and interview narrative explaining design decisions,
  verification, tradeoffs, measured results, and remaining limitations.

## Implementation sequence

The compute array, NPU, DMA, compiler, and initial Basys3 self-test form the
established baseline. The active completion sequence is:

| Step | Status | Evidence or remaining work |
|---|---|---|
| 1. Integrated SoC testbench | Complete | The compiler-generated program DMA-loads A/B through a stalled external-memory model, executes, DMA-stores C, and checks every result plus arbitration behavior. |
| 2. Robust error handling | Complete | Structured faults and negative tests cover invalid opcodes/dimensions, address and program bounds, DMA selector/range errors, no-op commands, busy arbitration, and recovery. |
| 3. Randomized differential verification | **Complete** | A deterministic Python harness generates signed shapes, partial K/N tiles, K accumulation, padded strides, boundary values, and seeded memory stalls; the integrated SoC result is checked against the Python golden model. The default 16-case seed, an independent 16-case seed, and a 64-case stress seed pass. |
| 4. Host-programmable FPGA demo | **Next** | Add a UART loader for instructions and matrix data, and return results/status over UART while retaining the button-driven self-test. |
| 5. Real FPGA evidence | Pending | Run both Vivado flows, review routed timing/utilization/DRC/power, generate the bitstream, program Basys3, and capture a concise demonstration. |
| 6. ASIC implementation evidence | Pending | Run the Sky130 OpenLane/OpenROAD flow and publish reproducible area, timing, power, DRC, and LVS evidence with exact tool versions. |
| 7. First stable release | Pending | Create `v0.1.0` after the integrated regressions pass, including an archive, checksums, known limitations, supported configurations, and reproduction commands. |

The completed AXI4-Lite control wrapper is a useful host-integration enhancement,
but it does not replace step 4's board-accessible UART loader.

## Current work

Step 3 is implemented and passing. The next implementation milestone is
**step 4: host-programmable FPGA demo**. A failure from the randomized suite can
be replayed exactly with:

```sh
python scripts/run_randomized_differential.py --seed <seed> --case-index <index>
```

Generated matrices, programs, golden outputs, and simulator logs are retained
under `build/randomized_differential/`.

## Scope control

Follow the numbered sequence and prioritize closure and presentation of the
existing design over unrelated feature growth. Step 6 is academic ASIC-flow
evidence, not commercial production qualification. Commercial licensing,
production SRAM productization, formal certification, additional operators or
numeric formats, and a qualified 16x16 product remain outside the active scope.

Update this file whenever a milestone changes so the repository has one clear,
shared source of truth for project status.
