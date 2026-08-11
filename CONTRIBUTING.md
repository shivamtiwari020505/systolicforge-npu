# Contributing to SystolicForge

SystolicForge welcomes focused fixes, verification improvements, documentation,
and extensions that preserve the repository's reproducible hardware/software
contract.

## Development setup

The standard regression needs Python 3.10+ and Icarus Verilog:

```sh
make test
```

The complete evidence pipeline additionally needs Verilator, Yosys, and
Graphviz:

```sh
make evidence
```

On Windows, the functional regression is available without Make:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_all_tests.ps1
```

## Change expectations

- Keep synthesizable RTL parameterized and compatible with both Icarus and
  Verilator.
- Add a self-checking regression for functional changes. Do not rely on visual
  waveform inspection as the correctness check.
- Update `docs/ISA.md` when instruction encoding or software-visible behavior
  changes.
- Regenerate committed diagrams with `make waveforms diagrams`; CI rejects
  stale generated evidence.
- Label synthesis-only, pre-route, theoretical, and measured results precisely.
  Include tool and PDK versions with any new utilization, timing, power, DRC, or
  LVS claim.
- Keep generated build products under `build/`; do not commit logs, netlists,
  bitstreams, VCDs, or local planning material.

## Pull requests

Keep each pull request scoped to one coherent change. Describe the affected
hardware/software contract, list the commands run, and call out any warning or
test that could not be reproduced. `git diff --check` and the relevant test or
evidence target should pass before review.

Bug reports are most useful when they include the command, tool version, target
configuration, complete error text, and a minimal reproducer.
