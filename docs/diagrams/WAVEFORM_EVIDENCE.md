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
| `npu_instruction_waveform.svg` | `tb/tb_systolicforge_npu.sv` (4×4, two tiled MATMULs) | `880db6bbfa66751321f6e76596bf5e1d309c42dae65079bf355e6b4af05b4ad9` | 170 |

The mini-NPU testbench observes `done` 168 falling-edge sample intervals
after the start pulse is accepted. This is the same execution reported by the
self-checking simulation as 168 cycles. Sampling on falling edges shows stable
state after positive-edge sequential logic has settled.

The VCD files stay under `build/waves/` and are intentionally ignored by Git.
The hashes above cover the named signal widths, timestamps, and transitions used
by each renderer while deliberately excluding non-semantic VCD headers such as
the run date.
