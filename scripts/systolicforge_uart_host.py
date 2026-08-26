#!/usr/bin/env python3
"""Program and exercise the SystolicForge Basys3 demo over USB-UART."""

from __future__ import annotations

import argparse
import struct
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from compiler.systolicforge_compile import compile_graph, load_json_graph  # noqa: E402


CMD_PING = 0x00
CMD_STATUS = 0x01
CMD_WRITE_PROGRAM = 0x10
CMD_WRITE_MEMORY = 0x11
CMD_READ_MEMORY = 0x12
CMD_START = 0x20

RESPONSE_OK = 0x00
MEM_A = 0
MEM_B = 1
MEM_C = 2
PROTOCOL_ID = 0x53464E50

BOARD_ARRAY_ROWS = 8
BOARD_ARRAY_COLS = 8
BOARD_SCRATCHPAD_WORDS = 128
BOARD_IMEM_WORDS = 16


class ByteTransport(Protocol):
    def write(self, data: bytes) -> int | None: ...

    def read(self, size: int) -> bytes: ...

    def close(self) -> None: ...


class UARTProtocolError(RuntimeError):
    """The board returned an invalid or unsuccessful protocol response."""


@dataclass(frozen=True)
class BoardStatus:
    raw: int
    busy: bool
    done: bool
    fault: bool
    self_test_active: bool
    self_test_pass: bool
    self_test_fail: bool
    framing_error: bool
    command_error: bool
    fault_code: int
    pc: int
    protocol_version: int

    @classmethod
    def decode(cls, value: int) -> "BoardStatus":
        return cls(
            raw=value,
            busy=bool(value & (1 << 0)),
            done=bool(value & (1 << 1)),
            fault=bool(value & (1 << 2)),
            self_test_active=bool(value & (1 << 3)),
            self_test_pass=bool(value & (1 << 4)),
            self_test_fail=bool(value & (1 << 5)),
            framing_error=bool(value & (1 << 6)),
            command_error=bool(value & (1 << 7)),
            fault_code=(value >> 8) & 0xF,
            pc=(value >> 12) & 0xF,
            protocol_version=(value >> 16) & 0xFFFF,
        )


class SystolicForgeUART:
    """Blocking client for the one-request-at-a-time board protocol."""

    def __init__(self, transport: ByteTransport):
        self.transport = transport

    def close(self) -> None:
        self.transport.close()

    def _read_exact(self, size: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < size:
            chunk = self.transport.read(size - len(chunks))
            if not chunk:
                raise UARTProtocolError(
                    f"UART response ended after {len(chunks)} of {size} bytes"
                )
            chunks.extend(chunk)
        return bytes(chunks)

    def request(self, command: int, payload: bytes = b"") -> int:
        if not 0 <= command <= 0xFF:
            raise ValueError("command must fit in one byte")
        packet = bytes((command,)) + payload
        written = self.transport.write(packet)
        if written is not None and written != len(packet):
            raise UARTProtocolError(
                f"UART write accepted {written} of {len(packet)} bytes"
            )

        response_command, response_status, data = struct.unpack(
            "<BBI", self._read_exact(6)
        )
        expected_command = command | 0x80
        if response_command != expected_command:
            raise UARTProtocolError(
                f"response command 0x{response_command:02x}, "
                f"expected 0x{expected_command:02x}"
            )
        if response_status != RESPONSE_OK:
            status_names = {
                1: "busy",
                2: "unknown command",
                3: "invalid argument",
            }
            detail = status_names.get(response_status, "unknown status")
            raise UARTProtocolError(
                f"command 0x{command:02x} failed: {detail} "
                f"(0x{response_status:02x})"
            )
        return data

    def ping(self) -> int:
        identifier = self.request(CMD_PING)
        if identifier != PROTOCOL_ID:
            raise UARTProtocolError(
                f"unexpected board identifier 0x{identifier:08x}"
            )
        return identifier

    def status(self) -> BoardStatus:
        return BoardStatus.decode(self.request(CMD_STATUS))

    def write_program(self, address: int, instruction: int) -> None:
        if not 0 <= address < BOARD_IMEM_WORDS:
            raise ValueError(f"program address must be 0..{BOARD_IMEM_WORDS - 1}")
        if not 0 <= instruction < (1 << 128):
            raise ValueError("instruction must fit in 128 bits")
        payload = bytes((address,)) + instruction.to_bytes(16, "little")
        self.request(CMD_WRITE_PROGRAM, payload)

    def write_memory(self, memory: int, address: int, value: int) -> None:
        self._validate_memory_address(memory, address)
        payload = bytes((memory, address)) + (value & 0xFFFFFFFF).to_bytes(4, "little")
        self.request(CMD_WRITE_MEMORY, payload)

    def read_memory(self, memory: int, address: int) -> int:
        self._validate_memory_address(memory, address)
        return self.request(CMD_READ_MEMORY, bytes((memory, address)))

    @staticmethod
    def _validate_memory_address(memory: int, address: int) -> None:
        if memory not in (MEM_A, MEM_B, MEM_C):
            raise ValueError("memory must be MEM_A, MEM_B, or MEM_C")
        if not 0 <= address < BOARD_SCRATCHPAD_WORDS:
            raise ValueError(
                f"scratchpad address must be 0..{BOARD_SCRATCHPAD_WORDS - 1}"
            )

    def start(self) -> None:
        self.request(CMD_START)

    def wait_until_done(self, timeout: float = 2.0) -> BoardStatus:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.status()
            if status.done:
                if status.fault:
                    raise UARTProtocolError(
                        f"execution-engine fault 0x{status.fault_code:x} "
                        f"at PC {status.pc}"
                    )
                return status
            time.sleep(0.01)
        raise UARTProtocolError(
            f"execution engine did not finish within {timeout:.3f} seconds"
        )


def _read_hex_words(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text(encoding="ascii").splitlines()]


def run_graph(client: SystolicForgeUART, graph_path: Path) -> tuple[int, int]:
    """Compile, upload, execute, and compare one JSON MatMul graph."""
    matrix_a, matrix_b, name = load_json_graph(graph_path)
    with tempfile.TemporaryDirectory(prefix="systolicforge_uart_") as temp_dir:
        artifact_dir = Path(temp_dir)
        manifest = compile_graph(
            matrix_a=matrix_a,
            matrix_b=matrix_b,
            name=name,
            output_dir=artifact_dir,
            array_rows=BOARD_ARRAY_ROWS,
            array_cols=BOARD_ARRAY_COLS,
            scratchpad_depth=BOARD_SCRATCHPAD_WORDS,
            imem_depth=BOARD_IMEM_WORDS,
        )

        program = _read_hex_words(artifact_dir / "program.hex")
        matrix_a_words = _read_hex_words(artifact_dir / "a.hex")
        matrix_b_words = _read_hex_words(artifact_dir / "b.hex")
        expected_c = _read_hex_words(artifact_dir / "c_expected.hex")

        for address, instruction in enumerate(program):
            client.write_program(address, instruction)
        for address, value in enumerate(matrix_a_words):
            client.write_memory(MEM_A, address, value)
        for address, value in enumerate(matrix_b_words):
            client.write_memory(MEM_B, address, value)

        client.start()
        client.wait_until_done()
        actual_c = [client.read_memory(MEM_C, address) for address in range(len(expected_c))]
        mismatches = sum(actual != expected for actual, expected in zip(actual_c, expected_c))
        return mismatches, manifest["scratchpad_words"]["C"]


def _open_serial(port: str, baud: int, timeout: float) -> ByteTransport:
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError(
            "pyserial is required for board access; install it with "
            "'python -m pip install pyserial'"
        ) from exc
    return serial.Serial(port=port, baudrate=baud, timeout=timeout, write_timeout=timeout)


def _format_status(status: BoardStatus) -> str:
    return (
        f"raw=0x{status.raw:08x} version={status.protocol_version} "
        f"busy={int(status.busy)} done={int(status.done)} "
        f"fault={int(status.fault)} fault_code=0x{status.fault_code:x} pc={status.pc} "
        f"self_test=active:{int(status.self_test_active)},"
        f"pass:{int(status.self_test_pass)},fail:{int(status.self_test_fail)} "
        f"uart_errors=framing:{int(status.framing_error)},"
        f"command:{int(status.command_error)}"
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="serial port, for example COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("ping", help="check the protocol identifier")
    subparsers.add_parser("status", help="read board/engine status")
    run_parser = subparsers.add_parser("run", help="compile and execute a JSON MatMul")
    run_parser.add_argument("graph", type=Path)
    return parser


def main() -> int:
    args = build_argument_parser().parse_args()
    try:
        transport = _open_serial(args.port, args.baud, args.timeout)
        client = SystolicForgeUART(transport)
        try:
            if args.action == "ping":
                print(f"SystolicForge board responded: 0x{client.ping():08x}")
            elif args.action == "status":
                print(_format_status(client.status()))
            else:
                client.ping()
                mismatches, result_words = run_graph(client, args.graph)
                if mismatches:
                    print(f"FAIL: {mismatches} of {result_words} result words differ")
                    return 1
                print(f"PASS: all {result_words} result words match the compiler model")
        finally:
            client.close()
    except (OSError, RuntimeError, ValueError, UARTProtocolError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
