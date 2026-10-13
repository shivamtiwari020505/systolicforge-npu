# Waveform evidence

The SVG timing diagrams in this directory are derived from Icarus Verilog VCD
output. They are not hand-authored timing claims. Regenerate the VCDs and SVGs
with:

```sh
make waveforms
```

| Rendered evidence | Testbench | Canonical signal-trace SHA-256 | Displayed samples |
|---|---|---|---:|
| `systolic_array_waveform.svg` | `tb/tb_systolic_array.sv` (4×4, M=6, one input bubble) | `51ce8fbcf76bf6d486df95d6b5dfc8e40d4bbbc27d787c59d45f92dc2573e542` | 19 |
| `npu_instruction_waveform.svg` | `tb/tb_systolicforge_npu.sv` (4×4, two tiled MATMULs) | `d166486624308ff8af3e543b4f86314de214a521fbb789cb25a59ff03beb688c` | 84 |

The mini-NPU testbench observes `done` 82 falling-edge sample intervals
after the start pulse is accepted. This is the same execution reported by the
self-checking simulation as 82 cycles. Sampling on falling edges shows stable
state after positive-edge sequential logic has settled.

The VCD files stay under `build/waves/` and are intentionally ignored by Git.
The hashes above cover the named signal widths, timestamps, and transitions used
by each renderer while deliberately excluding non-semantic VCD headers such as
the run date.
