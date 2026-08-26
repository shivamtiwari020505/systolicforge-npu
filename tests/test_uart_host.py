import struct
import unittest

from scripts.systolicforge_uart_host import (
    BoardStatus,
    CMD_PING,
    CMD_STATUS,
    CMD_WRITE_PROGRAM,
    PROTOCOL_ID,
    SystolicForgeUART,
    UARTProtocolError,
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


if __name__ == "__main__":
    unittest.main()
