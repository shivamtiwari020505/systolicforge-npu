# FPGA timing/reset correction and rerun record

## Supplied Vivado evidence (before this correction)

The October 13 full-profile archive (`build.zip`, SHA-256
`B861B8926B6290646476D248A880E33A4707A7B3EC8481E259BC6129801CD8DD`)
contains a Vivado 2025.2 completed synthesis manifest, checkpoint and reports
for `systolicforge_soc`, 8x8 INT8/INT32, 4096 words per scratchpad and
256 instruction words. Its recorded source commit is unknown and it lacks
the log/journal. These provenance gaps prevent auditing every synthesis warning.

| Post-synthesis metric | Value |
|---|---:|
| RAMB36E1 | 8 |
| Slice LUTs | 1480 (7.12%) |
| Flip-flops | 1923 (4.62%) |
| DSP48E1 | 75 (83.33%) |
| WNS at 10 ns | -7.392 ns |
| TNS | -1121.326 ns |
| Failing setup endpoints | 198 |

RAM inference succeeded; 100 MHz timing did not. The worst estimated path runs
from instruction BRAM output through address/bounds arithmetic to issue-register
enables: 17.106 ns, 14 logic levels, including two cascaded DSPs. DRC/methodology
also flag asynchronous-reset RAM/DSP drivers, incomplete DSP/BRAM pipelining and
missing OOC interface delays. These are not routed or board-measured results.

## Implemented correction

- `systolicforge_matmul_validator` is shared by both execution engines. It
  captures operands, computes registered unsigned 8x16 products, adds registered
  25-bit address tails, then checks ranges. Full 16-bit ISA bases/strides are
  checked before engine-local address truncation. Fault priority remains
  dimension, program overrun, then address range.
- Compute waits for validation before reading operands or issuing a result.
  Reset discards incomplete validations. NOP/HALT/illegal-opcode behavior is
  unchanged.
- A/B/C row pointers advance by stride instead of multiplying row by stride
  on every access. Strides of zero, padding, high addresses and ordered general
  NPU accumulation are retained.
- NPU, DMA, AXI host, array/PE and UART control resets are synchronous. The
  physical reset button enters a two-stage clocked synchronizer initialized
  asserted. RAM arrays remain reset-free and pending C writes are suppressed
  while reset is asserted. Hold `rst_n` low across a rising edge; between-edge
  pulses are not a supported core reset contract.
- Only used row-skew stages are reset/implemented. PE latency remains one cycle;
  there is no new PE format or extra MAC lane.
- Basys3 now checks both routed setup and hold slack, routing errors and DRC
  errors before requesting a bitstream. No internal timing exception or warning
  suppression was added. OOC manifests explicitly distinguish completed
  synthesis from a passing estimated setup target.

This reset choice follows AMD's guidance that BRAM/DSP sequential resources
support synchronous reset and asynchronous reset can prevent register packing:
[UG901 coding guidelines](https://docs.amd.com/r/2024.2-English/ug901-vivado-synthesis/Coding-Guidelines).

## Local verification (not Vivado timing closure)

- Array signed arithmetic, bubbles and zero/narrow-accumulator wrap tests pass.
- 263 dedicated validator cases cover exact/end-plus-one boundaries, full-width
  bases/strides, maximum M, zero strides, back-to-back response alignment, fault
  priority and reset cancellation against an independent 64-bit calculation.
- 32 full-depth legacy/golden cases, overflow, padded/overlapping strides,
  memory guards, PC/faults, retained stalled reads and pending-write reset pass.
- Compiler-DMA-SoC example passes at 128/16, 256/16 and 4096/256 capacities:
  494 compute cycles, 120 A reads, 100 B reads and 8 A/C overlap cycles. The
  earlier prefetch-only version took 478 cycles; validation adds four cycles per
  MATMUL (16 in this example). Clock-period improvements are not board-measured.
- Compact engine compiler test checks all 60 results; bit-level UART regression
  checks signed execution, invalid requests, arbitration and button self-test.
- Default 16-case and independent 64-case Python-versus-RTL differential suites
  pass (stress seed `0x052a671d`), including seeded external-memory stalls.
- Verilator lint and generic mapped-array simulation pass. Yosys 0.33 full SoC
  maps to eight BRAMs and 67 DSPs; Basys3 maps to 69 DSPs. Both pass structural
  checks; neither contains asynchronous-reset FF primitives. These are
  pre-place estimates, not Vivado routed utilization.
- Python compiler/host and stubbed Tcl-flow tests pass. Tcl tests exercise
  manifest/failure/bitstream gates only; they do not implement an FPGA.

Reproduce with `make test lint gate-sim synth-npu-full synth-xc7 waveforms` and
`python -m unittest discover -s tests -v` (Python Tk is required for Tcl tests).

## Required external acceptance

Run [FPGA_RERUN.md](../FPGA_RERUN.md) from a fresh package. The launcher creates
timestamped directories, records source hashes/tool version/exit codes and
packages complete results without overwriting old runs. Return both successful
and failing reports/logs.

Confirm the redesigned sources infer eight full-profile BRAMs, inspect timing
and reset-control warnings, then check Basys3 routed setup/hold, route status,
DRC and bitstream. Program the board and verify UART and button tests.
OOC I/O delay budgets belong to the eventual synchronous integration contract;
the internal-only OOC clock does not validate the external interface.

## October 14 external rerun accepted

The [complete evidence record](evidence/vivado/2026-10-14/README.md) now archives
both returned ZIPs and all reports/logs. Full-NPU synthesis infers eight BRAMs
and 67 DSPs, with +2.098 ns post-synthesis WNS and no failing setup endpoints.
Basys3 achieves routed 100 MHz setup/hold (+0.036/+0.067 ns), zero failing
timing endpoints/routing errors, and a generated bitstream. Its setup margin
is narrow; full-NPU routing is not covered by the OOC run.

The old memory-inference/too-many-ports warning classes and async RAM/DSP-driver
checks are absent from the new logs/report summaries. Optimization and OOC
interface/clock-source advisories remain; all warnings are preserved. Power is
vectorless estimated, not board-measured. Both manifests retain unknown Git
provenance; incoming runs lack source hashes.

Implementation evidence is complete. Program the board and archive the button
self-test, UART PING plus full example result check, and photo/video before
marking roadmap step 5 complete. No board operation or measured power claim
is made yet.
