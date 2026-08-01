#!/usr/bin/env python3
"""Compile one quantized MatMul into the SystolicForge mini-NPU instruction format."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Sequence


OP_NOP = 0x0
OP_MATMUL = 0x1
OP_HALT = 0xF
FLAG_ACCUMULATE = 0x1


@dataclass(frozen=True)
class MatMulInstruction:
    flags: int
    m: int
    k: int
    n: int
    a_base: int
    b_base: int
    c_base: int
    lda: int
    ldb: int
    ldc: int

    @property
    def opcode(self) -> int:
        return OP_MATMUL

    def encode(self) -> int:
        fields = (
            ("flags", self.flags, 4),
            ("m", self.m, 8),
            ("k", self.k, 8),
            ("n", self.n, 8),
            ("a_base", self.a_base, 16),
            ("b_base", self.b_base, 16),
            ("c_base", self.c_base, 16),
            ("lda", self.lda, 16),
            ("ldb", self.ldb, 16),
            ("ldc", self.ldc, 16),
        )
        for name, value, width in fields:
            if value < 0 or value >= (1 << width):
                raise ValueError(f"{name}={value} does not fit in {width} bits")

        word = OP_MATMUL
        word |= self.flags << 4
        word |= self.m << 8
        word |= self.k << 16
        word |= self.n << 24
        word |= self.a_base << 32
        word |= self.b_base << 48
        word |= self.c_base << 64
        word |= self.lda << 80
        word |= self.ldb << 96
        word |= self.ldc << 112
        return word


@dataclass(frozen=True)
class QuantizedMatrix:
    values: list[list[int]]
    scale: float


def _validate_rectangular(matrix: Sequence[Sequence[Any]], name: str) -> tuple[int, int]:
    if not isinstance(matrix, Sequence) or isinstance(matrix, (str, bytes)) or not matrix:
        raise ValueError(f"{name} must be a non-empty 2-D matrix")
    if not isinstance(matrix[0], Sequence) or isinstance(matrix[0], (str, bytes)):
        raise ValueError(f"{name} must be a 2-D matrix")
    cols = len(matrix[0])
    if cols == 0:
        raise ValueError(f"{name} must have at least one column")
    for row in matrix:
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes)):
            raise ValueError(f"{name} must be a 2-D matrix")
        if len(row) != cols:
            raise ValueError(f"{name} is ragged")
        for value in row:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"{name} contains a non-numeric value")
            if not math.isfinite(value):
                raise ValueError(f"{name} contains a non-finite value")
    return len(matrix), cols


def quantize_matrix(matrix: Sequence[Sequence[int | float]], name: str) -> QuantizedMatrix:
    _validate_rectangular(matrix, name)
    flat = [value for row in matrix for value in row]
    already_int8 = all(isinstance(value, int) and -128 <= value <= 127 for value in flat)

    if already_int8:
        return QuantizedMatrix([[int(value) for value in row] for row in matrix], 1.0)

    max_abs = max(abs(float(value)) for value in flat)
    scale = max_abs / 127.0 if max_abs else 1.0
    quantized = [
        [max(-128, min(127, round(float(value) / scale))) for value in row]
        for row in matrix
    ]
    return QuantizedMatrix(quantized, scale)


def load_json_graph(path: Path) -> tuple[list[list[int | float]], list[list[int | float]], str]:
    with path.open("r", encoding="utf-8") as stream:
        graph = json.load(stream)
    if graph.get("op", "MatMul") != "MatMul":
        raise ValueError("the JSON frontend currently supports only op='MatMul'")
    if "A" not in graph or "B" not in graph:
        raise ValueError("the JSON graph must contain A and B matrices")
    return graph["A"], graph["B"], graph.get("name", path.stem)


def load_onnx_graph(
    path: Path, a_data_path: Path | None
) -> tuple[list[list[int | float]], list[list[int | float]], str]:
    try:
        import onnx
        from onnx import numpy_helper
    except ImportError as exc:
        raise RuntimeError(
            "the ONNX frontend requires the optional 'onnx' package; "
            "install it or use the dependency-free JSON frontend"
        ) from exc

    model = onnx.load(str(path))
    matmuls = [node for node in model.graph.node if node.op_type == "MatMul"]
    if len(matmuls) != 1:
        raise ValueError("the ONNX frontend expects exactly one MatMul node")

    node = matmuls[0]
    initializers = {
        tensor.name: numpy_helper.to_array(tensor).tolist()
        for tensor in model.graph.initializer
    }

    if node.input[1] not in initializers:
        raise ValueError("the MatMul B input must be an ONNX initializer")
    matrix_b = initializers[node.input[1]]

    if node.input[0] in initializers:
        matrix_a = initializers[node.input[0]]
    elif a_data_path is not None:
        with a_data_path.open("r", encoding="utf-8") as stream:
            data = json.load(stream)
        matrix_a = data.get("A", data) if isinstance(data, dict) else data
    else:
        raise ValueError(
            "the MatMul A input is dynamic; provide its 2-D values with --a-data"
        )

    return matrix_a, matrix_b, model.graph.name or path.stem


def tile_matmul(
    m_size: int,
    k_size: int,
    n_size: int,
    array_rows: int,
    array_cols: int,
) -> list[MatMulInstruction]:
    if min(m_size, k_size, n_size, array_rows, array_cols) <= 0:
        raise ValueError("matrix and array dimensions must be positive")
    if array_rows > 255 or array_cols > 255:
        raise ValueError("array dimensions must fit in the ISA's 8-bit size fields")

    instructions: list[MatMulInstruction] = []
    for m0 in range(0, m_size, 255):
        tile_m = min(255, m_size - m0)
        for n0 in range(0, n_size, array_cols):
            tile_n = min(array_cols, n_size - n0)
            for k0 in range(0, k_size, array_rows):
                tile_k = min(array_rows, k_size - k0)
                instructions.append(
                    MatMulInstruction(
                        flags=FLAG_ACCUMULATE if k0 else 0,
                        m=tile_m,
                        k=tile_k,
                        n=tile_n,
                        a_base=m0 * k_size + k0,
                        b_base=k0 * n_size + n0,
                        c_base=m0 * n_size + n0,
                        lda=k_size,
                        ldb=n_size,
                        ldc=n_size,
                    )
                )
    return instructions


def matmul_reference(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    m_size = len(a)
    k_size = len(a[0])
    n_size = len(b[0])
    return [
        [sum(a[row][inner] * b[inner][col] for inner in range(k_size))
         for col in range(n_size)]
        for row in range(m_size)
    ]


def _write_hex(path: Path, values: Sequence[int], digits: int) -> None:
    mask = (1 << (digits * 4)) - 1
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for value in values:
            stream.write(f"{value & mask:0{digits}x}\n")


def compile_graph(
    matrix_a: Sequence[Sequence[int | float]],
    matrix_b: Sequence[Sequence[int | float]],
    name: str,
    output_dir: Path,
    array_rows: int,
    array_cols: int,
    scratchpad_depth: int,
    imem_depth: int,
) -> dict[str, Any]:
    a_rows, a_cols = _validate_rectangular(matrix_a, "A")
    b_rows, b_cols = _validate_rectangular(matrix_b, "B")
    if a_cols != b_rows:
        raise ValueError(f"MatMul shape mismatch: A is {a_rows}x{a_cols}, B is {b_rows}x{b_cols}")

    a_quant = quantize_matrix(matrix_a, "A")
    b_quant = quantize_matrix(matrix_b, "B")
    program = tile_matmul(a_rows, a_cols, b_cols, array_rows, array_cols)
    if len(program) + 1 > imem_depth:
        raise ValueError(
            f"program needs {len(program) + 1} words, but IMEM depth is {imem_depth}"
        )

    footprints = {"A": a_rows * a_cols, "B": b_rows * b_cols, "C": a_rows * b_cols}
    for memory, words in footprints.items():
        if words > scratchpad_depth:
            raise ValueError(
                f"{memory} needs {words} words, but scratchpad depth is {scratchpad_depth}"
            )

    reference = matmul_reference(a_quant.values, b_quant.values)
    output_dir.mkdir(parents=True, exist_ok=True)

    encoded_program = [instruction.encode() for instruction in program] + [OP_HALT]
    _write_hex(output_dir / "program.hex", encoded_program, 32)
    _write_hex(
        output_dir / "a.hex",
        [value for row in a_quant.values for value in row],
        2,
    )
    _write_hex(
        output_dir / "b.hex",
        [value for row in b_quant.values for value in row],
        2,
    )
    _write_hex(
        output_dir / "c_expected.hex",
        [value for row in reference for value in row],
        8,
    )

    manifest: dict[str, Any] = {
        "name": name,
        "op": "MatMul",
        "shape": {"M": a_rows, "K": a_cols, "N": b_cols},
        "array": {"rows": array_rows, "cols": array_cols},
        "quantization": {
            "a_scale": a_quant.scale,
            "b_scale": b_quant.scale,
            "output_scale": a_quant.scale * b_quant.scale,
            "accumulator": "signed_int32",
        },
        "scratchpad_words": footprints,
        "instruction_count": len(encoded_program),
        "instructions": [
            {"pc": pc, **asdict(instruction)}
            for pc, instruction in enumerate(program)
        ]
        + [{"pc": len(program), "opcode": "HALT"}],
        "artifacts": {
            "program": "program.hex",
            "a": "a.hex",
            "b": "b.hex",
            "expected_c": "c_expected.hex",
        },
    }
    with (output_dir / "manifest.json").open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    return manifest


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Tile and compile one MatMul for the SystolicForge mini-NPU"
    )
    parser.add_argument("graph", type=Path, help="MatMul JSON graph or .onnx model")
    parser.add_argument(
        "-o", "--output", type=Path, default=Path("build/program"),
        help="artifact directory (default: build/program)",
    )
    parser.add_argument("--a-data", type=Path, help="JSON values for a dynamic ONNX A input")
    parser.add_argument("--array-rows", type=int, default=8)
    parser.add_argument("--array-cols", type=int, default=8)
    parser.add_argument("--scratchpad-depth", type=int, default=4096)
    parser.add_argument("--imem-depth", type=int, default=256)
    return parser


def main() -> int:
    args = build_argument_parser().parse_args()
    try:
        if args.graph.suffix.lower() == ".onnx":
            matrix_a, matrix_b, name = load_onnx_graph(args.graph, args.a_data)
        else:
            matrix_a, matrix_b, name = load_json_graph(args.graph)

        manifest = compile_graph(
            matrix_a=matrix_a,
            matrix_b=matrix_b,
            name=name,
            output_dir=args.output,
            array_rows=args.array_rows,
            array_cols=args.array_cols,
            scratchpad_depth=args.scratchpad_depth,
            imem_depth=args.imem_depth,
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}")
        return 2

    shape = manifest["shape"]
    print(
        f"compiled {shape['M']}x{shape['K']} @ {shape['K']}x{shape['N']} "
        f"into {manifest['instruction_count']} instructions at {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
