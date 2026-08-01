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

Unknown opcodes stop execution and assert `fault`.

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

## Example tiling

For M=3, K=10, N=10 on an 8×8 array, the compiler emits four MATMULs:

1. N columns 0–7, K elements 0–7, replace C.
2. N columns 0–7, K elements 8–9, accumulate C.
3. N columns 8–9, K elements 0–7, replace C.
4. N columns 8–9, K elements 8–9, accumulate C.

A final `HALT` makes the program five words long.
