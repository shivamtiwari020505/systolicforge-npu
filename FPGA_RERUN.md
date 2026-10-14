# FPGA closure handoff (v5)

Extract this project into a fresh directory. Open Vivado Command Prompt and
change into the extracted directory containing `Makefile` and `rtl/`.

```bat
fpga\vivado\run_vivado.cmd full
fpga\vivado\run_vivado.cmd basys3
```

Or run both sequentially with `fpga\vivado\run_vivado.cmd all`. The second flow
does not depend on the first. Requires Artix-7 support for `xc7a35tcpg236-1`.

The launcher creates a fresh timestamped run directory under
`build/vivado_runs/` before opening any logs. It records hashes of the actual
RTL/constraints/build scripts, the tool version and process exit codes. On
normal completion or a tool error it packs a results ZIP and prints its path.
Return that ZIP; keep failed runs and their warnings too. If the shell is killed,
package the timestamped directory manually after Vivado has stopped.

`full` is synthesis only: 8x8 array, general NPU/DMA, 4096 words per scratchpad
and 256 instructions. Estimated WNS is recorded; a synthesis-completed message
is not timing closure. Top-level I/O delays remain integration-specific and are
not modeled by this internal-path OOC characterization.

`basys3` implements the compact 128-word/16-instruction UART engine. It checks
routed setup and hold slack, routing errors and DRC errors before generating
the board bitstream. Power is a vectorless estimate, not a board measurement.

The October 13 reports predate this fix: 8 BRAMs inferred successfully but
post-synthesis WNS was -7.392 ns. This handoff stages instruction validation,
uses incrementing row pointers and synchronous RAM/DSP control resets, and
synchronizes the board reset. It does not loosen the 100 MHz target or suppress
warnings. See [the closure record](docs/FPGA_CLOSURE.md) for checks and limits.

The October 14 direct CMD rerun now has archived full-NPU synthesis and compact
Basys3 routed timing/bitstream evidence. See
[the archived record](docs/evidence/vivado/2026-10-14/README.md). Physical-board
validation remains pending; program and test following
[the handoff](fpga/vivado/VIVADO_HANDOFF.md). The launcher now selects one
executable and records the version in Tcl manifests without a blocking native
`-version` preflight. These launcher-only changes do not alter the FPGA RTL.
