# SystolicForge ISA

Instructions are fixed-width 128-bit little-field words. Hex files print the
entire word most-significant nibble first, as expected by SystemVerilog
`$readmemh`.

## Opcodes

| Opcode | Mnemonic | Meaning |
|---:|---|---|
| `0x0` | `NOP` | Advance PC without changing architectural state |
| `0x1` | `MATMUL` | Execute one M×K by K×N tile |
| `0xf` | `HALT` | Deassert busy and pulse done |

Unknown opcodes stop execution, pulse `done`, and report fault code `0x1`.

## MATMUL layout

| Bits | Field | Description |
|---:|---|---|
| 3:0 | opcode | `0x1` |
| 7:4 | flags | Bit 0 is `ACCUMULATE`; other bits are reserved |
| 15:8 | m | Number of output rows, 1–255 |
| 23:16 | k | Inner tile, 1–`ARRAY_ROWS` |
| 31:24 | n | Output columns, 1–`ARRAY_COLS` |
| 47:32 | a_base | A scratchpad word address |
| 63:48 | b_base | B scratchpad word address |
| 79:64 | c_base | C scratchpad word address |
| 95:80 | lda | A row stride in INT8 words |
| 111:96 | ldb | B row stride in INT8 words |
| 127:112 | ldc | C row stride in INT32 words |

The instruction computes:

```text
for i in 0 .. m-1
  for j in 0 .. n-1
    sum = Σ A[a_base + i*lda + p] * B[b_base + p*ldb + j]
    C[c_base + i*ldc + j] = ACCUMULATE ? C[...] + sum : sum
```

All operands are signed INT8, and the sum and C are signed INT32. There is no
rounding, activation, saturation, or requantization instruction in this version.

The scheduled general NPU commits C in increasing row/column order, as in the
pseudocode above, including overlapping C strides. The saved legacy engine
could issue conflicting writes for those shapes, so legacy equivalence is
checked for non-overlapping C; overlapping C uses the ISA's ordered semantics.
Accumulation wraps at INT32 width. Execution cycles are not part of the ISA.

## Bounds checks

Before a `MATMUL` changes architectural state, hardware computes the highest
word address touched in each scratchpad:

```text
A_last = a_base + (m - 1) * lda + (k - 1)
B_last = b_base + (k - 1) * ldb + (n - 1)
C_last = c_base + (m - 1) * ldc + (n - 1)
```

All three addresses must be less than `2**ADDR_W`. The compiler applies the
same check against its configured `--scratchpad-depth`. This permits zero or
non-unit strides when their complete access range remains valid.

A `NOP` or `MATMUL` in the last instruction-memory word reports program
overrun, because execution would otherwise wrap to PC zero. `HALT` remains
valid in the last word.

DMA commands accept memory selectors 0 (A), 1 (B), and 2 (C). Before issuing an
external request, the DMA validates the complete local word range and external
byte range and requires the external address to be word-aligned. A zero-length
DMA command with a valid memory selector is a successful no-op: `dma_done`
pulses without setting a fault or emitting a request.

## Fault reporting

`fault` is the summary indication and `fault_code[3:0]` identifies the cause:

| Code | Name | Condition |
|---:|---|---|
| `0x0` | `NONE` | No outstanding fault |
| `0x1` | `ILLEGAL_OPCODE` | Instruction opcode is not NOP, MATMUL, or HALT |
| `0x2` | `ILLEGAL_DIMENSION` | M/K/N is zero or the K/N tile exceeds the physical array |
| `0x3` | `ADDRESS_RANGE` | A, B, or C strided access exceeds its scratchpad |
| `0x4` | `PROGRAM_OVERRUN` | NOP or MATMUL would advance beyond instruction memory |
| `0x5` | `DMA_INVALID_MEMORY` | DMA memory selector is not A, B, or C |
| `0x6` | `DMA_LOCAL_RANGE` | DMA local word range exceeds the scratchpad |
| `0x7` | `DMA_EXTERNAL_ADDRESS` | DMA external byte range wraps or is not word-aligned |

NPU faults remain asserted until the next accepted `start`. DMA faults remain
asserted until the next accepted DMA command. Rejected operations pulse their
corresponding completion signal without entering busy or performing memory
side effects. At the integrated SoC output, an NPU code has priority if both
subsystems retain a fault.

The AXI4-Lite wrapper exposes this summary and code in its `STATUS` register and
retains completion/fault causes in write-one-to-clear interrupt status. See
[`HOST_INTERFACE.md`](HOST_INTERFACE.md) for the register contract.

## Example tiling

For M=3, K=10, N=10 on an 8×8 array, the compiler emits four MATMULs:

1. N columns 0–7, K elements 0–7, replace C.
2. N columns 0–7, K elements 8–9, accumulate C.
3. N columns 8–9, K elements 0–7, replace C.
4. N columns 8–9, K elements 8–9, accumulate C.

A final `HALT` makes the program five words long.
