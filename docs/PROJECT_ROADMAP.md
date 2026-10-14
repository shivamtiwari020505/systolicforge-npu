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
| 4. Host-programmable FPGA demo | **Complete** | A 115200 8N1 loader programs instructions and A/B/C data, starts the compact ISA-compatible FPGA engine, and returns status/results. The compiler-generated five-word example matches all 60 golden outputs in the engine regression; a bit-level UART regression covers request/response framing, busy arbitration, signed execution, result readback, invalid requests, and the retained shared-engine button self-test. |
| 5. Real FPGA evidence | **In progress: implementation evidence complete, board test pending** | October 14 full-NPU Vivado synthesis: 8 BRAMs and estimated WNS +2.098 ns. Compact Basys3: routed 100 MHz WNS +0.036 ns, WHS +0.067 ns, no failing endpoints/routing errors, bitstream generated. Complete archives and reports retained in docs/evidence/vivado/2026-10-14. Physical button/UART demonstration remains pending. |
| 6. ASIC implementation evidence | Pending | Run the Sky130 OpenLane/OpenROAD flow and publish reproducible area, timing, power, DRC, and LVS evidence with exact tool versions. |
| 7. First stable release | Pending | Create `v0.1.0` after the integrated regressions pass, including an archive, checksums, known limitations, supported configurations, and reproduction commands. |

The AXI4-Lite control wrapper remains the general SoC host boundary. The
resource-bounded Basys3 path uses the same ISA and compiler contract but
uses compact distributed RAM in a separate FPGA engine. The general NPU uses
full-depth synchronous block RAM. Both retain the 8×8 array and ISA.

## Current work

Steps 1–4 are implemented and passing. The next milestone is **step 5: real
FPGA evidence**. The implementation submilestone is now achieved: full-NPU OOC
synthesis and compact Basys3 routed timing/bitstream reports are archived in
[the October 14 evidence record](evidence/vivado/2026-10-14/README.md).
Next validate the button self-test and `scripts/systolicforge_uart_host.py`
on a physical Basys3. Board operation remains unclaimed until demonstration
and host logs are archived; step 5 is not yet complete.

The 2026-10-12 default-depth OOC attempt passed the original elaboration limit
but expanded memories into very large register/mux structures (over 9 GB peak
memory in the supplied log); the user stopped it after more than an hour.
The corrected October 14 Basys3 run meets routed timing and generates the
bitstream. The optional compact OOC profile keeps
the general 8x8 NPU and DMA with 128-word scratchpads and 16 instructions. Its
reports must identify these capacities, and cannot stand in for the 4096-word,
256-instruction default configuration. See the
[Vivado handoff](../fpga/vivado/VIVADO_HANDOFF.md) for commands and limits.

The full-capacity synchronous-memory correction is implemented in the general
NPU and SoC. Instruction/A/B/C storage uses synchronous SDP RAM, prefetched
tiles, one row in flight, and pipelined C writeback. Full-depth SoC simulation
and legacy/golden comparisons pass. Complete SoC Yosys mapping produces eight
block RAMs without a dissolve-limit override. The October 13 Vivado OOC run
confirmed eight BRAMs; the October 14 correction now passes the setup estimate.
Full-NPU OOC remains separate from the compact Basys3 routed result. Step 5
remains in progress until board evidence is archived. See
[MEMORY_ARCHITECTURE_REDESIGN.md](MEMORY_ARCHITECTURE_REDESIGN.md).

The first latency phase is locally verified: pipelined reads, active-lane
prefetch, and two activation row buffers reduce the compiler example from
1246 to 478 compute cycles. Staged validation now takes 494 compute cycles,
with full capacities and eight-BRAM mapping retained. See
[FPGA_CLOSURE.md](FPGA_CLOSURE.md) and [the rerun instructions](../FPGA_RERUN.md).
Multiple rows in flight and banking remain optional follow-up performance work;
physical board validation is the next external milestone. Full-NPU routing
remains outside the supplied OOC synthesis result.

A failure from the randomized suite can still be replayed exactly with:

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
