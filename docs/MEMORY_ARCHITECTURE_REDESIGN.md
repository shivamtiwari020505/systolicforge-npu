# Synchronous memory-architecture correction

## Status and purpose

The scheduled synchronous-memory correction is implemented in
`rtl/systolicforge_npu.sv` and used by `systolicforge_soc`. The original engine
is saved in `tb/reference/systolicforge_npu_legacy.sv` for comparisons.
Directed integration and legacy/golden tests pass; complete full-depth SoC
mapping infers eight block RAMs. External Vivado and board evidence are pending.

The redesign preserves the existing software-visible contract:

- 8x8 signed INT8 array with signed INT32 results;
- 4096 words in each default A, B, and C scratchpad;
- 256 128-bit instruction words;
- the existing NOP/MATMUL/HALT encoding, bases, strides, and accumulation bit;
- the DMA local-memory selectors and word addressing;
- current fault behavior and compute/DMA mutual exclusion.

The compact Basys3 engine remains a separate demonstration target while this
general NPU work proceeds.

## Why the existing organization does not map

The saved legacy implementation reads up to 64 B words and eight A words through
combinational array indexing and can update several C addresses in one cycle.
Those accesses were also mixed with DMA writes in an asynchronously reset
control process. A normal FPGA block RAM or ASIC SRAM macro cannot provide that
logical port count. Vivado therefore dissolved the arrays into registers and
multiplexers; the interrupted default-depth run exceeded 9 GB of host memory
and reported internal instances with more than 500,000 pins.

Increasing Vivado's dissolve limit changes only where elaboration stops. It
does not provide a physical memory implementation.

## Foundation now in the repository

`rtl/systolicforge_sdp_ram.sv` is the portable storage primitive for the first
migration stage. It has one synchronous read port, one synchronous write port,
one-cycle registered read data, read-first collision behavior, and no reset on
the array or output. The controller, rather than the memory, owns validity.

`tb/tb_systolicforge_sdp_ram.sv` checks the first and last words of the full
4096-word address range, registered-read hold behavior, and same-address
read/write semantics. `synth/systolicforge_memory_smoke.sv` instantiates the
complete default storage capacity—A, B, C, and instruction memory—through the
same primitive. It is a synthesis harness, not an NPU implementation.

Reproduce the foundation checks with:

```sh
make memory-foundation
make memory-foundation-synth
```

The synthesis result establishes only that the proposed storage shapes infer
as device memory. It is not evidence that the redesigned controller, array,
or complete SoC fits or meets timing.

The 2026-10-12 Yosys 0.33 Xilinx-7 smoke run mapped the complete 229,376 stored
bits to eight `RAMB36E1` primitives: one each for A and B, four for C, and two
for instruction memory. `check -assert` reported zero structural problems. The
synthesis script asserts that exact block-RAM count so inference regressions
fail CI instead of silently producing a large logic implementation.

## First implementation: scheduled synchronous memory

The replacement schedules synchronous reads and C writes while retaining full
capacities and the SoC/DMA interface. Each word prefetch has request/capture
phases. One activation row is in flight, and its final C write commits before
the next row starts.

```text
DMA / program ports
        |
        v
  arbitration (DMA only while compute idle)
        |
        +--> synchronous instruction RAM --> fetch/decode register
        +--> synchronous A RAM -----------+
        +--> synchronous B RAM -----------+--> prefetch controller
        +--> synchronous C RAM <----------+--> accumulation/writeback
                                             |
                            +----------------+
                            v
                  weight and activation tile registers
                            |
                            v
                        8x8 array
                            |
                            v
                  result capture/writeback pipeline
```

Required controller phases are:

1. Fetch the instruction and wait for the registered RAM output.
2. Validate dimensions and full-width address calculations before side effects.
3. Prefetch the active KxN weight tile into 64 small registers; zero inactive
   lanes for partial tiles.
4. Prefetch one K-element activation row; zero inactive lanes.
5. Issue the row to the array, then repeat activation prefetch for all M rows.
6. Capture results and perform C read-modify-write through an explicitly
   pipelined synchronous read path when `ACCUMULATE` is set.
7. Advance the PC only after the last committed C write, not merely after the
   last array output appears.

The implemented row issue interval includes activation prefetch, array drain
and C writeback. It depends on physical rows and active columns, rather than
the board engine's fixed `ARRAY_ROWS + 1` spacing. The mini-NPU regression
takes 168 cycles and the 8x8 compiler example takes 1246 compute cycles (legacy:
23 and 81). This trades throughput for full-depth memory mapping. Banking and
overlap remain optional performance improvements.

## Memory and collision contract

- Memory arrays are never cleared by reset. Software/DMA initializes all words
  that an accepted instruction can read.
- All memory reads are synchronous. Address and enable are presented in cycle
  N; registered data is consumed in cycle N+1.
- The primitive is read-first for a same-address collision. The controller must
  not depend on a vendor-specific alternative mode.
- DMA owns the memories only while compute is idle, matching the current SoC
  arbitration contract.
- C accumulation is a read-modify-write dependency. Address, result, valid, and
  last-result metadata must travel through the same latency pipeline.
- `done` means the final architectural write is committed. No buffered result
  may remain when `done` asserts.
- Bounds checks use widened arithmetic and complete before prefetch or writeback.

## Second implementation: throughput-oriented banking

Banking is an optimization after the scheduled version is functionally and
physically proven. A likely eight-bank organization uses:

```text
bank = word_address % 8
row  = word_address / 8
```

This makes any aligned or unaligned run of up to eight consecutive A or B words
conflict-free, which matches one activation row and one B-tile row. It does not
guarantee conflict-free C traffic for arbitrary `ldc` and wavefront timing.
Consequently, C outputs require per-lane buffering plus a bank arbiter, or a
row-result buffer followed by scheduled writeback. Conflicts must stall the
memory scheduler without dropping or reordering results.

Banking must not be merged merely because an 8x8 directed test passes. It needs
randomized strides, bases, partial tiles, accumulation, and sustained-conflict
tests, plus a proof that every accepted result is eventually committed.

## Completed local migration

1. Portable SDP RAM and default-capacity storage smoke harness.
2. General NPU replacement with synchronous fetch/prefetch and C writeback.
3. Saved legacy engine and 32 full-depth comparisons with independent golden
   calculations, signed values, accumulation overflow, high addresses, guards,
   M=255, zero input strides, PC=255, faults, reset and stalled reads.
   Extra checks cover pending-write reset cancellation, selector changes, and
   overlapping C against the ordered ISA calculation. A separate seeded
   64-case integrated Python/RTL stress suite also passes.
4. SoC integration, local DMA read backpressure and simultaneous-command
   arbitration; compiler, AXI-Lite and fault regressions pass.
5. Full 4096/4096/4096/256 SoC mapping: eight RAMB36E1, 73 DSP48E1,
   1213 LUT primitives and 4074 flip-flops in Yosys 0.33; no structural errors.
   `make synth-npu-full` enforces the block-RAM count.
6. Vivado sources include the RAM primitive and the dissolve override is
   removed. Vivado execution and archived reports are pending.
7. Banking remains future performance work.

## Acceptance gates

The scheduled redesign is complete only when all of the following hold:

- Existing directed, fault, compiler, SoC, AXI-Lite, and randomized tests pass.
- A dedicated old-versus-new differential regression passes for signed values,
  partial K/N tiles, padded strides, accumulation, address boundaries, and
  reset/restart sequences.
- Full default capacities (4096/4096/4096/256) are used in synthesis evidence.
- Tool reports show inferred memories rather than hundreds of thousands of
  scratchpad-related LUT/register cells.
- Simulation checks the one-cycle memory latency and final-write-before-done
  rule; no test reads internal arrays hierarchically to bypass the interface.
- Vivado completes synthesis without memory-dissolve-limit overrides.
- Placement, routing, timing, and bitstream status are reported only from their
  corresponding archived artifacts.

## Performance evidence after correctness

Report both peak array arithmetic and measured end-to-end execution. At minimum
record cycles spent in instruction fetch, weight prefetch, activation prefetch,
array issue/drain, C accumulation/writeback, and DMA. This exposes whether a
future banking or double-buffering change improves the actual workload rather
than only the theoretical 64-MAC array peak.
