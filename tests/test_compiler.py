import json
import tempfile
import unittest
from pathlib import Path

from compiler.systolicforge_compile import (
    FLAG_ACCUMULATE,
    MatMulInstruction,
    compile_graph,
    matmul_reference,
    tile_matmul,
    validate_program_bounds,
)


class InstructionTests(unittest.TestCase):
    def test_instruction_bit_layout(self) -> None:
        instruction = MatMulInstruction(
            flags=1,
            m=3,
            k=4,
            n=5,
            a_base=0x1234,
            b_base=0x2345,
            c_base=0x3456,
            lda=0x4567,
            ldb=0x5678,
            ldc=0x6789,
        )
        word = instruction.encode()
        self.assertEqual(word & 0xF, 1)
        self.assertEqual((word >> 4) & 0xF, 1)
        self.assertEqual((word >> 8) & 0xFF, 3)
        self.assertEqual((word >> 16) & 0xFF, 4)
        self.assertEqual((word >> 24) & 0xFF, 5)
        self.assertEqual((word >> 32) & 0xFFFF, 0x1234)
        self.assertEqual((word >> 112) & 0xFFFF, 0x6789)

    def test_large_shape_is_tiled_across_all_dimensions(self) -> None:
        program = tile_matmul(260, 10, 10, 8, 8)
        self.assertEqual(len(program), 8)
        self.assertEqual([inst.m for inst in program], [255] * 4 + [5] * 4)
        self.assertEqual([inst.n for inst in program[:4]], [8, 8, 2, 2])
        self.assertEqual([inst.k for inst in program[:4]], [8, 2, 8, 2])
        self.assertEqual(
            [inst.flags for inst in program[:4]],
            [0, FLAG_ACCUMULATE, 0, FLAG_ACCUMULATE],
        )
        self.assertEqual(program[4].a_base, 2550)
        self.assertEqual(program[4].c_base, 2550)

    def test_strided_address_overflow_is_rejected(self) -> None:
        program = [
            MatMulInstruction(
                flags=0,
                m=2,
                k=2,
                n=2,
                a_base=127,
                b_base=0,
                c_base=0,
                lda=2,
                ldb=2,
                ldc=2,
            )
        ]
        with self.assertRaisesRegex(ValueError, "A address"):
            validate_program_bounds(program, scratchpad_depth=128)


class CompilerTests(unittest.TestCase):
    def test_compiler_emits_images_and_reference(self) -> None:
        matrix_a = [[1, -2, 3, 4, -5], [6, 7, -8, 9, 10]]
        matrix_b = [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
            [-1, -2, -3],
            [2, 0, -2],
        ]
        expected = matmul_reference(matrix_a, matrix_b)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            manifest = compile_graph(
                matrix_a,
                matrix_b,
                "unit_test",
                output,
                array_rows=4,
                array_cols=2,
                scratchpad_depth=128,
                imem_depth=32,
            )

            self.assertEqual(manifest["instruction_count"], 5)
            self.assertEqual(len((output / "program.hex").read_text().splitlines()), 5)
            self.assertEqual(len((output / "a.hex").read_text().splitlines()), 10)
            self.assertEqual(len((output / "b.hex").read_text().splitlines()), 15)
            actual_hex = (output / "c_expected.hex").read_text().splitlines()
            actual = [
                int(value, 16) if int(value, 16) < (1 << 31)
                else int(value, 16) - (1 << 32)
                for value in actual_hex
            ]
            self.assertEqual(actual, [value for row in expected for value in row])
            loaded_manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(loaded_manifest["shape"], {"M": 2, "K": 5, "N": 3})

    def test_shape_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "shape mismatch"):
                compile_graph(
                    [[1, 2]],
                    [[1, 2]],
                    "bad",
                    Path(directory),
                    8,
                    8,
                    64,
                    16,
                )

    def test_unsupported_scratchpad_depth_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "scratchpad depth"):
                compile_graph(
                    [[1]],
                    [[1]],
                    "bad_depth",
                    Path(directory),
                    8,
                    8,
                    (1 << 16) + 1,
                    16,
                )

    def test_program_without_room_for_halt_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "program needs 2 words"):
                compile_graph(
                    [[1]],
                    [[1]],
                    "no_halt_space",
                    Path(directory),
                    8,
                    8,
                    64,
                    1,
                )


if __name__ == "__main__":
    unittest.main()
