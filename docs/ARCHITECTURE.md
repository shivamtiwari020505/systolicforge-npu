# Architecture

## Compute array

The physical array has `ROWS × COLS` processing elements. `ROWS` is the K tile
size and `COLS` is the N tile size. Each PE contains:

- one stationary signed INT8 weight register;
- one registered activation hop to its eastern neighbor;
- one signed INT8 multiply;
- one signed 32-bit partial-sum register passed south.

Weights for a K×N tile are loaded before streaming begins. On each valid cycle,
the controller presents one logical row of A: `A[m][0:ROWS]`. Internal skew
registers delay lane `k` by `k` cycles. The activation then takes one additional
cycle per array column while the partial sum takes one cycle per array row.
Those two movements align `A[m][k] × B[k][n]` at every PE without a global
reduction tree.

Each output column has its own valid bit because columns drain on consecutive
cycles. After fill, every active column produces one result per cycle. The
datapath wraps on signed 32-bit overflow; it does not saturate.

## Mini-NPU

`systolicforge_npu` adds four architectural blocks around the array:

1. A 128-bit instruction memory and program counter.
2. Separate signed INT8 A and B scratchpads.
3. A signed INT32 C scratchpad.
4. A fetch/load/stream/drain sequencer.

The controller loads one B tile into the stationary weights, streams `m` A
rows, and writes each staggered output column to C. Strides are explicit in the
instruction, so tiles can refer directly to a larger row-major matrix rather
than being repacked.

K dimensions larger than the physical number of rows use multiple instructions.
The first instruction replaces C; later instructions set `ACCUMULATE` and add
their partial result to C. N is tiled across array columns, and M is split only
when it exceeds the ISA's 255-row limit.

The controller rejects zero dimensions, K tiles wider than `ARRAY_ROWS`, N tiles
wider than `ARRAY_COLS`, and unknown opcodes. Scratchpad bounds are a software
contract; the compiler validates its three image footprints before emission.

## DMA

`scratchpad_dma` accepts a local memory, local base, external byte address,
direction, and word count. It keeps at most one external read outstanding.

- Loads issue a 32-bit external read, wait for `ext_rsp_valid`, and write the
  response to the selected local scratchpad.
- Stores read the selected local address and hold a 32-bit external write request
  until `ext_req_ready`.

External addresses advance by four bytes and local addresses advance by one
word. A/B scratchpads consume the low byte of each loaded word; C consumes all
32 bits. `systolicforge_soc` prevents a compute start while the DMA is active, and the
NPU exposes its local port only while compute is idle.

Program memory has a separate configuration write port. This keeps the data DMA
simple and makes it easy to replace that port with AXI-Lite, APB, or a boot ROM
in a board-specific wrapper.

## Throughput

An R×C array contains R×C MACs. At full utilization, its arithmetic rate is:

```text
MAC/s = R × C × clock_frequency
ops/s = 2 × MAC/s
```

Thus an 8×8 array has a peak of 64 MAC/cycle, or 12.8 GOPS at 100 MHz when a
multiply and add are counted as two operations. Real utilization depends on tile
shape, array fill/drain, weight-load cycles, DMA traffic, and instruction gaps.
