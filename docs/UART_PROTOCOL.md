# Basys3 UART protocol

The Basys3 demonstration exposes its ISA-compatible FPGA execution engine over
the board's USB-UART bridge.
It is intentionally a small request/response protocol: the host sends one
request, waits for its six-byte response, and only then sends the next request.
This is sufficient to load compiler output, execute it, inspect status, and
read C results without adding a soft processor or a second SoC bus master.

## Link and board configuration

- 115200 baud, 8 data bits, no parity, one stop bit (`115200 8N1`)
- no hardware or software flow control
- little-endian multi-byte fields
- 16 words of 128-bit instruction memory
- 128 words in each A, B, and C scratchpad
- A/B words consume the low signed INT8 byte; C words use all signed INT32 bits

The RTL divisor is 868 clocks per bit at the Basys3 100 MHz input clock. The
host must not pipeline requests because the hardware holds only one request and
one response.

## Request and response framing

Each request begins with a one-byte command followed by the command-specific
payload. There is no length field because every command has a fixed payload.

Every response is exactly six bytes:

| Byte | Field | Meaning |
|---:|---|---|
| 0 | response command | request command OR `0x80`; `0xff` for an unknown command |
| 1 | response status | `0x00` OK, `0x01` busy, `0x02` unknown command, `0x03` invalid argument |
| 2–5 | data | unsigned 32-bit little-endian command result |

The response data is zero for commands without a return value. A busy or
invalid request has no side effect.

## Commands

| Command | Request payload | Response data |
|---:|---|---|
| `0x00` PING | none | `0x53464e50` (`SFNP`) |
| `0x01` STATUS | none | status word described below |
| `0x10` WRITE_PROGRAM | address byte, then 16 instruction bytes least-significant first | zero |
| `0x11` WRITE_MEMORY | memory byte, address byte, then four data bytes least-significant first | zero |
| `0x12` READ_MEMORY | memory byte, address byte | selected 32-bit word |
| `0x20` START | none | zero |

Memory selectors are `0` for A, `1` for B, and `2` for C. Instruction addresses
must be 0–15 and scratchpad addresses must be 0–127. Programming, memory, and
start commands return `busy` while compute or the button self-test owns the
NPU. PING and STATUS remain available.

### Status word

| Bits | Meaning |
|---:|---|
| 0 | execution engine busy |
| 1 | compute completion, sticky until the next start |
| 2 | execution-engine fault |
| 3 | button self-test active |
| 4 | most recent button self-test passed |
| 5 | most recent button self-test failed |
| 6 | UART framing error observed since reset |
| 7 | malformed/invalid command observed since reset |
| 11:8 | execution-engine fault code |
| 15:12 | current program counter |
| 31:16 | protocol version, currently `1` |

## Host utility

Install the optional serial dependency only on the computer used with the
board:

```sh
python -m pip install pyserial
```

Then verify the connection, inspect status, or compile and run the example:

```sh
python scripts/systolicforge_uart_host.py --port COM5 ping
python scripts/systolicforge_uart_host.py --port COM5 status
python scripts/systolicforge_uart_host.py --port COM5 run examples/matmul.json
```

On Linux, replace `COM5` with the appropriate device such as `/dev/ttyUSB0`.
The `run` command uses the existing compiler, checks the program and memory
footprints against the compact board configuration, uploads program/A/B,
starts compute, polls status, reads every C word, and compares it with the
compiler-generated reference.

## Button self-test interaction

BTNC still runs the deterministic signed 8×8 self-test, but it now uses the
same execution engine and scratchpads as the UART path. It writes instruction
locations 0 and 1 and A/B locations 0–63. A host should therefore upload its
program and operands again after pressing BTNC. Button requests are retained
until an in-flight UART response or compute operation finishes.

## Verification boundary

`tb/tb_fpga_uart_demo.sv` verifies the complete serial byte stream in RTL
simulation, including PING, busy arbitration, the button test, program and
operand writes, signed execution, status, result readback, and invalid memory
selection. This proves simulated protocol and functional behavior. Actual
USB-UART communication, bitstream generation, routed timing, and physical-board
results remain step 5 evidence and must be reported only after those artifacts
are captured.
