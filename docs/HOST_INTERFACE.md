# AXI4-Lite host interface

`systolicforge_axi_lite` is the software-visible integration wrapper around
`systolicforge_soc`. It provides a 32-bit AXI4-Lite register bank for program
loading, compute launch, DMA commands, status, structured faults, and a single
interrupt output. The existing external-memory request/response port passes
through unchanged.

The wrapper does not change the 128-bit instruction format or the scratchpad
DMA data path. Software-visible constants are also provided in
[`include/systolicforge_regs.h`](../include/systolicforge_regs.h).

## Bus contract

- 32-bit AXI4-Lite data and four byte write strobes.
- 8-bit default address width; all implemented registers are 32-bit aligned.
- One write response and one read response may be outstanding.
- AW and W are captured independently and may arrive in either order.
- `WSTRB` updates only the selected register bytes.
- `OKAY` (`2'b00`) means the access completed.
- `SLVERR` (`2'b10`) reports a write to a read-only register or a command that
  cannot be accepted in the current state.
- `DECERR` (`2'b11`) reports an unmapped or unaligned address.

The wrapper holds `BVALID`, `BRESP`, `RVALID`, `RRESP`, and `RDATA` until the
master accepts them. It does not support bursts, IDs, or multiple outstanding
transactions because those signals are outside AXI4-Lite.

## Register map

| Offset | Name | Access | Reset | Description |
|---:|---|---|---:|---|
| `0x00` | `ID` | RO | `0x53464e50` | SystolicForge NPU identifier |
| `0x04` | `VERSION` | RO | `0x00010000` | Register-interface version 1.0 |
| `0x08` | `CONTROL` | WO | `0` | Bit 0 is a write-one compute start command |
| `0x0c` | `STATUS` | RO | varies | Live compute, DMA, fault, IRQ, and readiness status |
| `0x10` | `IRQ_ENABLE` | RW | `0` | Interrupt enable bits `[2:0]` |
| `0x14` | `IRQ_STATUS` | RW1C | `0` | Sticky interrupt causes `[2:0]` |
| `0x20` | `PROGRAM_ADDR` | RW | `0` | Instruction-memory word address staged for commit |
| `0x24` | `PROGRAM_DATA_0` | RW | `0` | Instruction bits `[31:0]` |
| `0x28` | `PROGRAM_DATA_1` | RW | `0` | Instruction bits `[63:32]` |
| `0x2c` | `PROGRAM_DATA_2` | RW | `0` | Instruction bits `[95:64]` |
| `0x30` | `PROGRAM_DATA_3` | RW | `0` | Instruction bits `[127:96]` |
| `0x34` | `PROGRAM_COMMIT` | WO | `0` | Write bit 0 as one to write the staged instruction |
| `0x40` | `DMA_CONFIG` | RW | `0` | Direction and local-memory selector |
| `0x44` | `DMA_LOCAL_ADDR` | RW | `0` | Local scratchpad word address |
| `0x48` | `DMA_EXT_ADDR` | RW | `0` | External byte address |
| `0x4c` | `DMA_LENGTH` | RW | `0` | Transfer length in 32-bit words; valid bits `[15:0]` |
| `0x50` | `DMA_SUBMIT` | WO | `0` | Write bit 0 as one to submit the staged DMA command |

RO means read-only, WO means write-only command, and RW1C means readable with
write-one-to-clear status bits. Command registers read as zero.

## Status register

| Bits | Name | Meaning |
|---:|---|---|
| `0` | `COMPUTE_BUSY` | The NPU instruction sequencer is active |
| `1` | `DMA_BUSY` | A DMA transfer is active |
| `2` | `FAULT` | The integrated NPU or DMA retains a fault |
| `3` | `IRQ` | At least one enabled interrupt cause is pending |
| `7:4` | `FAULT_CODE` | Structured fault code from the integrated SoC |
| `8` | `DMA_READY` | A DMA command can currently be accepted |
| `31:9` | Reserved | Read as zero |

The fault code meanings and recovery rules are defined in
[`ISA.md`](ISA.md#fault-reporting).

## Interrupt behavior

`IRQ_ENABLE` and `IRQ_STATUS` use the same bits:

| Bit | Cause | Behavior |
|---:|---|---|
| `0` | `COMPUTE_DONE` | Set when the NPU pulses completion |
| `1` | `DMA_DONE` | Set when the DMA pulses completion, including a rejected or zero-length command |
| `2` | `FAULT` | Set while the integrated hardware fault indication is active |

The external interrupt is:

```text
irq = |(IRQ_ENABLE & IRQ_STATUS)
```

Completion bits are sticky until software writes ones to the corresponding
`IRQ_STATUS` bits. A fault clear cannot hide an active hardware fault: if bit 2
is cleared before the underlying NPU/DMA recovery command clears `FAULT`, the
hardware sets it again. New events take priority over a simultaneous RW1C
write, so completion pulses are not lost.

## Loading a program

Each 128-bit instruction is assembled from four little-word-order data
registers. For instruction address `pc`:

1. Write `PROGRAM_ADDR = pc`.
2. Write instruction bits `[31:0]` to `PROGRAM_DATA_0`.
3. Write bits `[63:32]`, `[95:64]`, and `[127:96]` to data registers 1–3.
4. Write `PROGRAM_COMMIT = 1`.
5. Check `BRESP` after every access.

Commit returns `SLVERR` and performs no instruction-memory write when compute is
busy or `PROGRAM_ADDR >= IMEM_DEPTH`. Staging-register writes are allowed at any
time, but changing staged data while another software context owns the device
requires driver-level serialization.

After the complete program, including `HALT`, is committed, write
`CONTROL.START = 1`. Start returns `SLVERR` while compute or DMA is busy.

## Issuing DMA commands

`DMA_CONFIG` has this layout:

| Bits | Name | Values |
|---:|---|---|
| `0` | `TO_LOCAL` | `1`: external-to-local load; `0`: local-to-external store |
| `2:1` | `MEMORY` | `0`: A, `1`: B, `2`: C, `3`: invalid/reserved |
| `31:3` | Reserved | Write zero |

Program `DMA_CONFIG`, `DMA_LOCAL_ADDR`, `DMA_EXT_ADDR`, and `DMA_LENGTH`, then
write `DMA_SUBMIT = 1`. The wrapper returns `SLVERR` without issuing a command
if the DMA is not ready or a 32-bit staging value cannot fit the configured RTL
field width. Once accepted, the DMA itself validates the memory selector, full
local and external ranges, word alignment, and overflow before any memory side
effect.

A zero-length command with memory A, B, or C is a successful no-op. It clears a
retained DMA fault, pulses `DMA_DONE`, and emits no external request.

## Recommended software sequence

```c
/* mmio_read32/mmio_write32 are platform-specific and must include any
 * ordering barriers required by the host CPU/interconnect. */

assert(mmio_read32(base + SYSTOLICFORGE_REG_ID) ==
       SYSTOLICFORGE_ID_VALUE);

mmio_write32(base + SYSTOLICFORGE_REG_IRQ_ENABLE,
             SYSTOLICFORGE_IRQ_ALL);

for (uint32_t pc = 0; pc < instruction_count; ++pc) {
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_ADDR, pc);
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_DATA_0, program[pc][0]);
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_DATA_1, program[pc][1]);
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_DATA_2, program[pc][2]);
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_DATA_3, program[pc][3]);
    mmio_write32(base + SYSTOLICFORGE_REG_PROGRAM_COMMIT, 1);
}

/* DMA-load A and B, waiting for DMA_DONE after each command. */
/* Start compute, then wait for COMPUTE_DONE or FAULT. */
mmio_write32(base + SYSTOLICFORGE_REG_CONTROL,
             SYSTOLICFORGE_CONTROL_START);
```

After an interrupt, read `IRQ_STATUS` and `STATUS` before clearing causes.
Handle `FAULT` first, issue the recovery command appropriate to the reported
code, verify that live `STATUS.FAULT` deasserts, then clear the sticky interrupt
bits.

## Concurrency and reset

The general NPU's internal scratchpad port now uses synchronous reads. Direct
RTL clients assert `dma_valid`, hold selector/address, and sample `dma_rdata`
only when `dma_ready` is high. A new read takes one clock edge; responses hold
while the request is held, including external DMA stalls. Idle command-ready
behavior and the software-visible register map are unchanged. Simultaneous
SoC compute-start and accepted DMA-command requests give priority to DMA.
Reset flushes control/pending responses without clearing RAM. Reset control
by holding active-low `rst_n` across a rising clock edge. The AXI, DMA,
NPU and PE control resets are synchronous; short between-edge pulses are not a
reset contract. Initialize all
memory words that a program reads before use. Instruction writes during
compute are ignored at the NPU port and rejected by the AXI wrapper.

- Compute and local DMA activity are mutually exclusive in
  `systolicforge_soc`.
- Start and DMA-submit command writes return `SLVERR` instead of being silently
  dropped when the requested engine is unavailable.
- AXI reset is active-low through `rst_n`. Reset clears staging registers,
  interrupt enable/status, pending AXI transactions, and the underlying SoC.
- Software must wait for reset deassertion and confirm `ID` before programming.

## Verification

Run the dedicated self-checking regression:

```sh
make axi-lite
```

The test deliberately presents AW before W, W before AW, and both together. It
checks byte strobes, access responses, staged program writes, interrupt
retention/clearing, command rejection while busy, wrapper field-width checks,
structured DMA fault recovery, and an end-to-end path that DMA-loads A=2 and
B=3, computes C=6, and DMA-stores the result.
