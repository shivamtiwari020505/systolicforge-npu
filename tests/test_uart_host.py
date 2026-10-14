import hashlib
import io
import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.systolicforge_uart_host import (
    BoardStatus,
    CMD_PING,
    CMD_STATUS,
    CMD_WRITE_PROGRAM,
    PROTOCOL_ID,
    SystolicForgeUART,
    UARTProtocolError,
    REPO_ROOT,
    run_graph,
    validate_board,
    main,
)


class FakeTransport:
    def __init__(self, response: bytes, chunk_size: int = 6):
        self.response = bytearray(response)
        self.chunk_size = chunk_size
        self.writes: list[bytes] = []
        self.closed = False

    def write(self, data: bytes) -> int:
        self.writes.append(data)
        return len(data)

    def read(self, size: int) -> bytes:
        count = min(size, self.chunk_size, len(self.response))
        result = bytes(self.response[:count])
        del self.response[:count]
        return result

    def close(self) -> None:
        self.closed = True


class UARTClientTests(unittest.TestCase):
    def test_ping_encodes_request_and_accepts_chunked_response(self) -> None:
        transport = FakeTransport(struct.pack("<BBI", 0x80, 0, PROTOCOL_ID), chunk_size=2)
        client = SystolicForgeUART(transport)

        self.assertEqual(client.ping(), PROTOCOL_ID)
        self.assertEqual(transport.writes, [bytes((CMD_PING,))])

    def test_program_word_is_little_endian(self) -> None:
        instruction = 0x112233445566778899AABBCCDDEEFF00
        transport = FakeTransport(struct.pack("<BBI", 0x90, 0, 0))
        client = SystolicForgeUART(transport)

        client.write_program(3, instruction)

        self.assertEqual(
            transport.writes[0],
            bytes((CMD_WRITE_PROGRAM, 3)) + instruction.to_bytes(16, "little"),
        )

    def test_status_fields_decode(self) -> None:
        status_word = (1 << 0) | (1 << 4) | (3 << 8) | (5 << 12) | (1 << 16)
        transport = FakeTransport(struct.pack("<BBI", 0x81, 0, status_word))
        status = SystolicForgeUART(transport).status()

        self.assertIsInstance(status, BoardStatus)
        self.assertTrue(status.busy)
        self.assertTrue(status.self_test_pass)
        self.assertEqual(status.fault_code, 3)
        self.assertEqual(status.pc, 5)
        self.assertEqual(status.protocol_version, 1)
        self.assertEqual(transport.writes, [bytes((CMD_STATUS,))])

    def test_board_error_becomes_exception(self) -> None:
        transport = FakeTransport(struct.pack("<BBI", 0xA0, 1, 0))
        client = SystolicForgeUART(transport)

        with self.assertRaisesRegex(UARTProtocolError, "busy"):
            client.start()

    def test_short_response_becomes_exception(self) -> None:
        transport = FakeTransport(b"\x80\x00")
        client = SystolicForgeUART(transport)

        with self.assertRaisesRegex(UARTProtocolError, "2 of 6 bytes"):
            client.ping()


class BoardEvidenceTests(unittest.TestCase):
    """Software-only capture tests; these do not constitute physical board evidence."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bitstream = self.root / "test.bit"
        self.bitstream.write_bytes(b"fake bitstream for unit tests only")
        self.graph = REPO_ROOT / "examples/matmul.json"
        self.output = self.root / "evidence"
        graph = json.loads(self.graph.read_text())
        self.expected = [
            sum(graph["A"][row][k] * graph["B"][k][col] for k in range(10)) & 0xFFFFFFFF
            for row in range(6) for col in range(10)
        ]
        self.good_status = BoardStatus.decode((1 << 16) | (1 << 4) | (1 << 1))
        self.client = Mock(spec=SystolicForgeUART)
        self.client.ping.return_value = PROTOCOL_ID
        self.client.status.return_value = self.good_status
        self.client.wait_until_done.return_value = self.good_status

    def read_report(self) -> dict:
        return json.loads((self.output / "board_result.json").read_text())

    def test_repeated_validation_captures_golden_actual_and_identity(self) -> None:
        self.client.read_memory.side_effect = self.expected * 3
        validate_board(self.client, self.graph, self.bitstream, self.output)

        report = self.read_report()
        self.assertEqual(report["outcome"], "PASS")
        self.assertEqual(len(report["completed_runs"]), 3)
        self.assertEqual(report["initial_status"]["raw"], self.good_status.raw)
        self.assertEqual(report["bitstream_sha256_operator_supplied"],
                         hashlib.sha256(self.bitstream.read_bytes()).hexdigest())
        self.assertEqual((self.output / "graph.json").read_bytes(), self.graph.read_bytes())
        self.assertEqual(self.client.start.call_count, 3)
        self.assertEqual(self.client.write_program.call_count, 15)
        for index in range(1, 4):
            run = self.output / f"run_{index:02d}"
            self.assertEqual((run / "c_actual.hex").read_text(),
                             (run / "c_expected.hex").read_text())
            self.assertEqual(json.loads((run / "result.json").read_text())["read_words"], 60)
            self.assertTrue((run / "manifest.json").is_file())

    def test_mismatch_keeps_failed_outputs_and_stops_repeats(self) -> None:
        self.client.read_memory.side_effect = [self.expected[0] ^ 1] + self.expected[1:]
        with self.assertRaisesRegex(UARTProtocolError, "1 of 60"):
            validate_board(self.client, self.graph, self.bitstream, self.output)
        self.assertEqual(self.read_report()["outcome"], "FAIL")
        run_report = json.loads((self.output / "run_01/result.json").read_text())
        self.assertEqual(run_report["mismatches"], 1)
        self.assertEqual(run_report["read_words"], 60)
        self.assertEqual(self.client.start.call_count, 1)

    def test_disconnection_preserves_partial_readback(self) -> None:
        self.client.read_memory.side_effect = self.expected[:2] + [UARTProtocolError("disconnected")]
        with self.assertRaisesRegex(UARTProtocolError, "disconnected"):
            validate_board(self.client, self.graph, self.bitstream, self.output)
        self.assertEqual(self.read_report()["outcome"], "ERROR")
        run = self.output / "run_01"
        self.assertEqual(len((run / "c_actual.hex").read_text().splitlines()), 2)
        self.assertEqual(json.loads((run / "result.json").read_text())["outcome"], "ERROR")

    def test_missing_button_test_is_not_hardware_pass(self) -> None:
        self.client.status.return_value = BoardStatus.decode(1 << 16)
        with self.assertRaisesRegex(UARTProtocolError, "press BTNC"):
            validate_board(self.client, self.graph, self.bitstream, self.output)
        self.assertEqual(self.read_report()["outcome"], "ERROR")
        self.client.start.assert_not_called()

    def test_unsafe_or_incompatible_status_is_rejected(self) -> None:
        # Busy, fault, self-test active/fail, UART errors and protocol mismatch.
        for status_word in [self.good_status.raw | (1 << bit) for bit in (0, 2, 3, 5, 6, 7)] + [2 << 16]:
            with self.subTest(status=status_word):
                self.client.status.return_value = BoardStatus.decode(status_word)
                output = self.root / f"status_{status_word}"
                with self.assertRaises(UARTProtocolError):
                    validate_board(self.client, self.graph, self.bitstream, output)
                self.assertEqual(json.loads((output / "board_result.json").read_text())["outcome"], "ERROR")
        self.client.start.assert_not_called()

    def test_final_uart_error_does_not_pass_even_when_words_match(self) -> None:
        self.client.read_memory.side_effect = self.expected
        self.client.status.side_effect = [
            self.good_status, BoardStatus.decode(self.good_status.raw | (1 << 6)),
        ]
        with self.assertRaisesRegex(UARTProtocolError, "error-free"):
            validate_board(self.client, self.graph, self.bitstream, self.output)
        self.assertEqual(self.read_report()["outcome"], "ERROR")

    def test_existing_evidence_is_not_overwritten(self) -> None:
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("previous evidence")
        with self.assertRaises(FileExistsError):
            validate_board(self.client, self.graph, self.bitstream, self.output)
        self.assertEqual(marker.read_text(), "previous evidence")
        self.client.ping.assert_not_called()

    def test_legacy_run_keeps_its_return_contract(self) -> None:
        self.client.read_memory.side_effect = self.expected
        self.assertEqual(run_graph(self.client, self.graph), (0, 60))

    def test_invalid_repeat_count_does_not_start_or_create_evidence(self) -> None:
        with self.assertRaisesRegex(ValueError, "positive"):
            validate_board(self.client, self.graph, self.bitstream, self.output, repeats=0)
        self.assertFalse(self.output.exists())
        self.client.start.assert_not_called()

    def test_cli_validation_closes_transport_on_success_and_failure(self) -> None:
        argv = [
            "host", "--port", "COM_TEST", "validate", str(self.graph),
            "--bitstream", str(self.bitstream), "--output", str(self.output),
        ]
        for error, exit_code in [(None, 0), (UARTProtocolError("failed"), 2)]:
            with self.subTest(exit_code=exit_code):
                transport = Mock()
                with patch("sys.argv", argv), patch("sys.stdout", new=io.StringIO()), \
                        patch("sys.stderr", new=io.StringIO()), \
                        patch("scripts.systolicforge_uart_host._open_serial", return_value=transport), \
                        patch("scripts.systolicforge_uart_host.validate_board", side_effect=error) as validate:
                    self.assertEqual(main(), exit_code)
                transport.close.assert_called_once()
                self.assertEqual(validate.call_args.args[4], 3)
                self.assertEqual(validate.call_args.args[5]["port"], "COM_TEST")


if __name__ == "__main__":
    unittest.main()
