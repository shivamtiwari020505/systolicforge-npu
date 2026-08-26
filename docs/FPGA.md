# FPGA implementation

The Basys3 target uses the Artix-7 XC7A35T and the board's 100 MHz oscillator.
The default top is `systolicforge_fpga_uart_demo`, an 8×8 INT8/INT32
ISA-compatible execution engine with a 115200-baud USB-UART control path and a
retained button-driven self-test.

The board configuration deliberately uses compact on-chip storage: 16
instruction words and 128 words in each A/B/C scratchpad. This fits the supplied
6×10 by 10×10 example while keeping the demonstration focused on the existing
compiler-to-accelerator path. It is not the default-depth SoC configuration
used by the separate out-of-context Vivado flow.

## Build

From the repository root:

```sh
vivado -mode batch -source fpga/vivado/build_basys3.tcl
```

The non-project script runs synthesis, optimization, placement, physical
optimization, routing, timing and DRC analysis, vectorless power estimation,
checkpoint creation, and bitstream generation. Its primary artifacts are:

```text
build/vivado_basys3/build_manifest.txt
build/vivado_basys3/utilization_synth.rpt
build/vivado_basys3/utilization_route.rpt
build/vivado_basys3/timing_summary_route.rpt
build/vivado_basys3/power_vectorless.rpt
build/vivado_basys3/drc_route.rpt
build/vivado_basys3/systolicforge_basys3.bit
```

The script rejects negative routed setup WNS before writing the bitstream. A
checked-in script or successful RTL simulation is not routed timing or
bitstream evidence; archive the generated reports before making those claims.

## UART operation

The Basys3 USB-UART bridge is connected at 115200 8N1. The binary protocol can
write 128-bit instructions, write or read A/B/C words, start compute, and read
status/fault information. The supplied host program compiles and checks a JSON
MatMul end to end:

```sh
python -m pip install pyserial
python scripts/systolicforge_uart_host.py --port COM5 ping
python scripts/systolicforge_uart_host.py --port COM5 status
python scripts/systolicforge_uart_host.py --port COM5 run examples/matmul.json
```

See [UART_PROTOCOL.md](UART_PROTOCOL.md) for the byte-level contract, memory
limits, status bits, and request arbitration rules.

## Button and LED behavior

- BTNU: asynchronous reset.
- BTNC: request or rerun the built-in engine self-test.
- LED0: latest button self-test passed.
- LED1: latest button self-test failed, or the engine reports a fault.
- LED2: compute or the button self-test is active.
- LED3: UART parser/response transaction is active.
- LED4: UART transmitter is active.
- LED5: compute completion is retained.
- LED6: a UART framing error has been observed since reset.
- LED7: an invalid/malformed command has been observed since reset.
- LEDs 11:8: execution-engine fault code.
- LEDs 15:12: execution-engine program counter.

The button test loads an 8×8 activation matrix and signed diagonal weights into
the same engine scratchpads used by UART, executes `MATMUL` followed by `HALT`,
and checks all 64 C words internally. It overwrites instruction locations 0–1 and
A/B locations 0–63, so host software should reload its workload afterward.
The two-stage button synchronizer handles metastability; it is not a full
mechanical debouncer.

## Reproducible pre-place checks

The complete serial path is exercised in simulation:

```sh
make fpga-engine
make fpga-uart-demo
```

The engine test executes the compiler-generated five-word tiled program and
checks all 60 outputs. The UART test bit-bangs request bytes, monitors
transmitted response bytes, proves busy arbitration during the button test,
uploads and executes a signed 1×1 MatMul, reads `-21` from C, and checks an
invalid memory request. The older
`make fpga-demo` target remains as a focused regression of the direct-array
self-test wrapper, but it is no longer the bitstream top.

`make synth-xc7` maps the current UART/engine top to Xilinx 7-series primitives
with Yosys. Counts recorded in [SYNTHESIS.md](SYNTHESIS.md) are pre-place
estimates, not Vivado placed-and-routed utilization or timing results.

Before programming a different Basys3 revision, compare
`fpga/basys3/basys3.xdc` against Digilent's master XDC for that board.
