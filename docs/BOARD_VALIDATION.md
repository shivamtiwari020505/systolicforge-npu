# Step 5: physical Basys3 validation

**Status: awaiting board access.** Vivado implementation evidence is complete;
physical operation is not yet verified. This checklist prepares the remaining
academic/interview milestone, not commercial qualification.

No new synthesis or routing run is needed to test the archived bitstream.
Do not change RTL just to perform this demonstration. The tested board design
is the compact 8x8 engine (16 instructions, 128 words per scratchpad), not the
full-depth NPU/DMA configuration.

## 1. Obtain board access and the existing bitstream

Borrow a Basys3 from a college lab or colleague if one is not available.
The board computer needs Vivado Hardware Manager with Artix-7 device support,
its cable drivers, Python 3, and a USB data cable. Digilent documents J4 as the
shared USB-JTAG/USB-UART connection in the
[Basys3 reference manual](https://digilent.com/reference/_media/reference/programmable-logic/basys-3/basys3_rm.pdf).
Follow that manual for power selection; do not use a charge-only cable.

From the repository root in **Command Prompt**, extract only the already-built
bitstream from the preserved evidence ZIP:

```bat
python -c "import zipfile; zipfile.ZipFile(r'docs/evidence/vivado/2026-10-14/archives/vivado_basys3.zip').extract('vivado_basys3/systolicforge_basys3.bit', r'build/board_programming')"
powershell -NoProfile -Command "(Get-FileHash 'build/board_programming/vivado_basys3/systolicforge_basys3.bit' -Algorithm SHA256).Hash"
```

Expected SHA-256 (case-insensitive):

```text
5E9600E2106FE49D89454C5C6C1F0C565E4B8B62A777D72805D0F8E04C6FBED9
```

Stop if the hash differs. The complete routed reports remain in
[the October 14 evidence record](evidence/vivado/2026-10-14/README.md).
Its incoming build did not record a Git commit/source inventory; retain that
provenance limitation rather than assigning the bitstream to a guessed commit.

## 2. Program the FPGA, not its flash

1. Connect the Basys3 through its J4 USB programming/UART connector and power it.
2. Open Vivado, then **Hardware Manager -> Open Target -> Auto Connect**.
3. Identify the Basys3 Artix-7 `xc7a35t` device. Do not program another connected
   board or select all devices indiscriminately.
4. Choose **Program Device** and select
   `build/board_programming/vivado_basys3/systolicforge_basys3.bit`.
   This design needs no debug-probes file.
5. Save the programming success message/screenshot. Use volatile JTAG
   programming; this procedure does not change QSPI flash. Power cycling loses
   the programmed design, so program it again after switching power off.

Programming the FPGA through Hardware Manager is separate from rebuilding a
design; see AMD's
[programming command documentation](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/program_hw_devices).

## 3. Button test and serial-port identification

1. Press/release **BTNU** to reset, then press/release **BTNC** once.
2. Wait for **LED0 on, LED1 off**, and no active compute on LED2.
3. Take a photo or short video of the board and those LEDs. The button test
   internally checks 64 signed results; it is separate from the host example.
4. On the board computer, install the serial dependency and list ports:

```bat
python -m pip install pyserial
python -m serial.tools.list_ports -v
```

Identify the USB-UART port by disconnecting/reconnecting the Basys3 and seeing
which port appears. Do not choose an unrelated COM port simply because it
exists. Close terminal programs using that port; the link is binary, not a text
terminal. Use 115200 baud, 8N1, no flow control.

In the commands below, **replace COM5 with the confirmed board port**:

```bat
set "BOARD_PORT=COM5"
python scripts\systolicforge_uart_host.py --port %BOARD_PORT% ping
python scripts\systolicforge_uart_host.py --port %BOARD_PORT% status
```

PING must return `0x53464e50`. STATUS must show version 1, idle, no fault/UART
errors, and `self_test=active:0,pass:1,fail:0`. Do not press BTNU between this
button test and the validation command: reset clears the pass flag.

## 4. Save repeated compiler-to-board comparisons

```bat
python scripts\systolicforge_uart_host.py --port %BOARD_PORT% validate examples\matmul.json --bitstream build\board_programming\vivado_basys3\systolicforge_basys3.bit --output build\board_validation\first_boot --repeats 3
```

Expected console output: three passing runs, each matching **all 60 C words**,
then an evidence-directory message. Each run reloads program/A/B before
starting; the host reload is required because the button test overwrites them.

The command requires a passed button test, compatible protocol, idle engine,
and no fault, framing error, or command error. It refuses an existing output
directory and stops on failure. Keep failures for diagnosis; do not delete
them and describe the run as passing. Communication failures after capture
starts produce an `ERROR` report and retain partial readback when available.
Errors before the evidence directory is created, such as a missing serial
package, appear on the console instead.

Saved files:

```text
first_boot/
  board_result.json       overall PASS/FAIL/ERROR, timestamps, status, hashes
  graph.json              exact input used for all runs
  run_01/                repeated as run_02/ and run_03/
    program.hex          instructions actually uploaded
    a.hex, b.hex         operands actually uploaded
    c_expected.hex       compiler golden result
    c_actual.hex         UART readback (partial on interruption)
    manifest.json        shape, tiling, compact capacities
    result.json          arithmetic comparison and completion status
```

The recorded bitstream hash is of the **file supplied by the operator**, not
hardware readback. Keep the Hardware Manager programming record to establish
which file was loaded. Host/compiler hashes identify the capture software;
they do not establish RTL provenance for the archived build.
An individual `result.json` PASS means matching arithmetic readback; the
session's `board_result.json` must also be PASS to establish healthy status.
This utility does not measure compute latency, sustained throughput, or power.

## 5. Reset recovery and evidence handoff

Without removing power, press/release BTNU and then BTNC again. Confirm the
button LEDs pass and repeat the same command with a **new** output directory:

```bat
python scripts\systolicforge_uart_host.py --port %BOARD_PORT% validate examples\matmul.json --bitstream build\board_programming\vivado_basys3\systolicforge_basys3.bit --output build\board_validation\after_reset --repeats 3
```

Add the programming screenshot and LED photo/video to `build/board_validation/`.
Record the operator, date, board model/revision, computer OS, Vivado version,
confirmed COM port, programmed bitstream hash, and any warnings or failures in
a short `notes.txt`. Then package **only the board evidence**, from CMD:

```bat
powershell -NoProfile -Command "Compress-Archive -LiteralPath 'build/board_validation' -DestinationPath 'build/board_validation_results.zip'"
```

Return `build/board_validation_results.zip`. There is no need to send the entire
project or rerun/send the existing Vivado archives. If an archive of that name
already exists, choose a new name so previous evidence is retained.

## Step 5 completion gate

- [ ] Correct archived bitstream verified and programmed on a physical Basys3.
- [ ] Button test passed, with photo/video and captured status.
- [ ] PING and three complete 60-word UART comparisons passed.
- [ ] Reset recovery and three further comparisons passed.
- [ ] Programming record, output files, operator notes and failures reviewed.
- [ ] Reviewed evidence archived under `docs/evidence/board/<date>/` and linked
      from the active roadmap before marking step 5 complete.

**Without a board, none of these physical checks can be ticked.** Automated
tests of the host capture code use mocked responses and are software tests
only. Existing Vivado results remain valid implementation evidence; they do
not substitute for the physical demonstration.
