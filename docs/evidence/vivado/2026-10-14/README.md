# Archived Vivado 2025.2 results: 2026-10-14

Both complete user-returned archives were run from the v5 launcher-fix project
directly in CMD. Working outputs are extracted into `build/vivado_npu_ooc_full/`
and `build/vivado_basys3/`. Original ZIPs, logs, journals, manifests and reports
are preserved here without editing their contents. Checkpoints, netlists, SDF
and bitstream remain in the complete ZIPs. `ARCHIVE_SHA256.csv` identifies them.

| Property | Full NPU OOC | Compact Basys3 UART demo |
|---|---|---|
| Top | `systolicforge_soc` | `systolicforge_fpga_uart_demo` |
| Device | `xc7a35tcpg236-1` | `xc7a35tcpg236-1` |
| Array / arithmetic | 8x8 / INT8, INT32 | 8x8 / INT8, INT32 |
| Scratchpad / instructions | 4096 words each / 256 | 128 words each / 16 |
| Stage | Synthesized, not routed | Routed and bitstream generated |
| Clock | 10.000 ns | 10.000 ns |
| Setup WNS | +2.098 ns (estimate) | +0.036 ns (routed) |
| Setup TNS / failing endpoints | 0.000 ns / 0 | 0.000 ns / 0 |
| Hold WHS / THS / failing endpoints | Not reported by max-only summary | +0.067 ns / 0.000 ns / 0 |
| Pulse-width slack / failing endpoints | +3.750 ns / 0 | +3.750 ns / 0 |
| Slice LUTs | 1536 (7.38%) | 1389 (6.68%) |
| Flip-flops | 1411 (3.39%) | 1795 (4.31%) |
| DSP48E1 | 67 (74.44%) | 67 (74.44%) |
| Block RAM tiles | 8 (16.00%) | 0 (distributed RAM) |
| Routing errors | Not applicable | 0; 6074/6074 routable nets fully routed |
| Board measured | No | No |

Basys3 meets the archived 100 MHz internal constraints, but setup margin is
only 36 ps. This is not broad frequency headroom, independently measured Fmax,
production qualification or physical board validation. Button/RX inputs enter
synchronizers; TX/LED outputs have no synchronous external capture contract.
There are no unconstrained internal endpoints or clockless registers reported.

## Primary evidence

- Full NPU: [manifest](vivado_npu_ooc_full/build_manifest.txt),
  [timing estimate](vivado_npu_ooc_full/timing_summary_synth.rpt),
  [utilization](vivado_npu_ooc_full/utilization_synth.rpt),
  [log](vivado_npu_ooc_full/vivado.log),
  [complete archive](archives/vivado_npu_ooc_full.zip).
- Basys3: [manifest](vivado_basys3/build_manifest.txt),
  [routed timing](vivado_basys3/timing_summary_route.rpt),
  [routed utilization](vivado_basys3/utilization_route.rpt),
  [route status](vivado_basys3/route_status.rpt),
  [DRC](vivado_basys3/drc_route.rpt),
  [methodology](vivado_basys3/methodology_route.rpt),
  [log](vivado_basys3/vivado.log),
  [complete archive including bitstream](archives/vivado_basys3.zip).

Bitstream: `systolicforge_basys3.bit`, 2,192,152 bytes, SHA-256:
`5E9600E2106FE49D89454C5C6C1F0C565E4B8B62A777D72805D0F8E04C6FBED9`.
Completion: `2026-10-13T18:57:15Z` (October 14 in IST).

## Warnings, power and provenance limits

Neither log contains an `ERROR:` or `CRITICAL WARNING:` diagnostic. The old
memory-dissolution/too-many-ports failure codes are absent from the new NPU log.
The asynchronous-driver (`DPIR-1`) and BRAM async-control (`REQP-1839`) checks
are absent from the new methodology/DRC summaries.

This is not warning-free. Full OOC DRC retains configuration-voltage and DSP
pipelining advice; methodology retains eight BRAM output-register advisories
and missing interface delay budgets. OOC clock-source/DRC coverage warnings
limit interpretation of its estimate. Full-NPU routing and customer interface
timing are not validated.

Basys3 DRC retains 13 warnings: one `DPOP-1`, eight `DPOP-2`, four `PLBUFGOPT-1`,
but no errors. Final methodology reports zero checks. Routing/physical
optimization logged intermediate negative timing and warnings (`Route 35-328`,
`Physopt 32-745`), followed by final positive setup/hold timing and bitstream
generation. Those warnings remain in the log, not suppressed or treated as
final signoff. Unused ports/registers and address-width trimming are retained.

[Power](vivado_basys3/power_vectorless.rpt) is a **vectorless estimate**:
0.106 W total on-chip, 0.035 W dynamic, 0.072 W static (rounded), medium
confidence, no activity file. This is not board power or energy per inference.

Both manifests record unknown Git commit/status. No source-hash inventory
accompanied the direct CMD runs. The recorded folder and validation/reset/
pointer metadata identify the reported v5 launcher-fix configuration, but do
not prove a specific tested Git revision. Future runs should retain source
hashes. Archive hashes establish artifact integrity, not source identity.

## Remaining acceptance

Program Basys3; capture the button self-test, UART PING and full compiler/
upload/result checks, plus board photo/video and host logs. Roadmap step 5
remains in progress until that hardware evidence exists. Older local outputs
are retained separately under `build/vivado_evidence/2026-10-13/` and the
earlier `build/build/` directories.
