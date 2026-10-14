# Waveform evidence

The SVG timing diagrams in this directory are derived from Icarus Verilog VCD
output. They are not hand-authored timing claims. Regenerate the VCDs and SVGs
with:

```sh
make waveforms
```

| Rendered evidence | Testbench | Canonical signal-trace SHA-256 | Displayed samples |
|---|---|---|---:|
| `systolic_array_waveform.svg` | `tb/tb_systolic_array.sv` (4×4, M=6, one input bubble) | `8c3b9ab5120177d47064a187698fb8e4530cc6ae5534940ceae5b0bf7d9f8a2c` | 19 |
| `npu_instruction_waveform.svg` | `tb/tb_systolicforge_npu.sv` (4×4, two tiled MATMULs) | `1adeaafba45a24034d96da126bc266076703e37039ba941cdd3c5f53805972aa` | 92 |

The mini-NPU testbench observes `done` 90 falling-edge sample intervals
after the start pulse is accepted. This is the same execution reported by the
self-checking simulation as 90 cycles. Sampling on falling edges shows stable
state after positive-edge sequential logic has settled.

The VCD files stay under `build/waves/` and are intentionally ignored by Git.
The hashes above cover the named signal widths, timestamps, and transitions used
by each renderer while deliberately excluding non-semantic VCD headers such as
the run date.
