#!/usr/bin/env python3
"""Run seed-reproducible randomized compiler/RTL differential verification."""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from compiler.systolicforge_compile import (  # noqa: E402
    FLAG_ACCUMULATE,
    OP_HALT,
    MatMulInstruction,
    matmul_reference,
    validate_program_bounds,
)


ARRAY_ROWS = 4
ARRAY_COLS = 4
SCRATCHPAD_WORDS = 256
IMEM_DEPTH = 32
DEFAULT_SEED = 0x5F2026D1
DEFAULT_CASES = 16
BOUNDARY_VALUES = (-128, -127, -64, -1, 0, 1, 63, 126, 127)


@dataclass(frozen=True)
class CaseSpec:
    m: int
    k: int
    n: int
    a_padding: int
    b_padding: int
    c_padding: int
    boundary_heavy: bool = False

    @property
    def lda(self) -> int:
        return self.k + self.a_padding

    @property
    def ldb(self) -> int:
        return self.n + self.b_padding

    @property
    def ldc(self) -> int:
        return self.n + self.c_padding


DIRECTED_CASES: tuple[CaseSpec, ...] = (
    CaseSpec(1, 1, 1, 0, 0, 0, True),
    CaseSpec(2, 3, 2, 2, 1, 3, True),
    CaseSpec(4, 4, 4, 1, 2, 1, False),
    CaseSpec(5, 5, 3, 2, 3, 2, True),
    CaseSpec(3, 9, 5, 3, 2, 3, False),
    CaseSpec(7, 8, 7, 1, 1, 2, True),
    CaseSpec(2, 12, 8, 2, 3, 1, False),
)


def parse_integer(value: str) -> int:
    """Accept decimal or Python-style hexadecimal command-line integers."""
    try:
        parsed = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return parsed


def case_seed(master_seed: int, case_index: int) -> int:
    """Derive a stable independent seed so one case can be replayed directly."""
    return (
        master_seed
        ^ (0x9E3779B97F4A7C15 * (case_index + 1))
        ^ (case_index << 32)
    ) & ((1 << 64) - 1)


def build_case_spec(master_seed: int, case_index: int) -> CaseSpec:
    if case_index < len(DIRECTED_CASES):
        return DIRECTED_CASES[case_index]

    rng = random.Random(case_seed(master_seed, case_index))
    m_size = rng.randint(1, 8)
    k_size = rng.randint(1, 12)
    n_size = rng.randint(1, 8)
    paddings = [rng.randint(0, 4) for _ in range(3)]
    if not any(paddings):
        paddings[rng.randrange(3)] = 1
    return CaseSpec(
        m=m_size,
        k=k_size,
        n=n_size,
        a_padding=paddings[0],
        b_padding=paddings[1],
        c_padding=paddings[2],
        boundary_heavy=(case_index % 3 == 0),
    )


def make_matrix(
    rows: int,
    columns: int,
    rng: random.Random,
    boundary_heavy: bool,
) -> list[list[int]]:
    values: list[list[int]] = []
    boundary_offset = rng.randrange(len(BOUNDARY_VALUES))
    for row in range(rows):
        output_row: list[int] = []
        for column in range(columns):
            flat_index = row * columns + column
            if boundary_heavy or rng.random() < 0.25:
                value = BOUNDARY_VALUES[
                    (boundary_offset + flat_index) % len(BOUNDARY_VALUES)
                ]
            else:
                value = rng.randint(-128, 127)
            output_row.append(value)
        values.append(output_row)
    return values


def build_strided_program(
    spec: CaseSpec,
    a_base: int,
    b_base: int,
    c_base: int,
) -> list[MatMulInstruction]:
    instructions: list[MatMulInstruction] = []
    for m_offset in range(0, spec.m, 255):
        tile_m = min(255, spec.m - m_offset)
        for n_offset in range(0, spec.n, ARRAY_COLS):
            tile_n = min(ARRAY_COLS, spec.n - n_offset)
            for k_offset in range(0, spec.k, ARRAY_ROWS):
                tile_k = min(ARRAY_ROWS, spec.k - k_offset)
                instructions.append(
                    MatMulInstruction(
                        flags=FLAG_ACCUMULATE if k_offset else 0,
                        m=tile_m,
                        k=tile_k,
                        n=tile_n,
                        a_base=a_base + m_offset * spec.lda + k_offset,
                        b_base=b_base + k_offset * spec.ldb + n_offset,
                        c_base=c_base + m_offset * spec.ldc + n_offset,
                        lda=spec.lda,
                        ldb=spec.ldb,
                        ldc=spec.ldc,
                    )
                )
    validate_program_bounds(instructions, SCRATCHPAD_WORDS)
    if len(instructions) + 1 > IMEM_DEPTH:
        raise ValueError(
            f"case needs {len(instructions) + 1} program words; limit is {IMEM_DEPTH}"
        )
    return instructions


def write_hex(path: Path, values: Sequence[int], digits: int) -> None:
    mask = (1 << (digits * 4)) - 1
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for value in values:
            stream.write(f"{value & mask:0{digits}x}\n")


def generate_case(
    master_seed: int,
    case_index: int,
    case_directory: Path,
) -> dict[str, object]:
    derived_seed = case_seed(master_seed, case_index)
    rng = random.Random(derived_seed)
    spec = build_case_spec(master_seed, case_index)

    matrix_a = make_matrix(spec.m, spec.k, rng, spec.boundary_heavy)
    matrix_b = make_matrix(spec.k, spec.n, rng, spec.boundary_heavy)
    golden = matmul_reference(matrix_a, matrix_b)

    # Independent scratchpads permit independent base offsets. Keep them small
    # while still exercising non-zero address bases and padding gaps.
    a_base = rng.randint(0, 7)
    b_base = rng.randint(0, 7)
    c_base = rng.randint(0, 7)
    a_words = (spec.m - 1) * spec.lda + spec.k
    b_words = (spec.k - 1) * spec.ldb + spec.n
    c_words = (spec.m - 1) * spec.ldc + spec.n

    if max(a_base + a_words, b_base + b_words, c_base + c_words) > SCRATCHPAD_WORDS:
        raise ValueError("generated strided image exceeds the scratchpad")

    instructions = build_strided_program(spec, a_base, b_base, c_base)
    encoded_program = [instruction.encode() for instruction in instructions]
    encoded_program.append(OP_HALT)
    encoded_program.extend([OP_HALT] * (IMEM_DEPTH - len(encoded_program)))

    a_storage = [0xA5] * SCRATCHPAD_WORDS
    b_storage = [0x5A] * SCRATCHPAD_WORDS
    for row in range(spec.m):
        for inner in range(spec.k):
            a_storage[a_base + row * spec.lda + inner] = matrix_a[row][inner] & 0xFF
    for inner in range(spec.k):
        for column in range(spec.n):
            b_storage[b_base + inner * spec.ldb + column] = (
                matrix_b[inner][column] & 0xFF
            )

    c_initial = [
        (0x60000000 ^ ((derived_seed + index * 0x45D9F3B) & 0x0FFFFFFF))
        & 0xFFFFFFFF
        for index in range(SCRATCHPAD_WORDS)
    ]
    c_expected = list(c_initial)
    for row in range(spec.m):
        for column in range(spec.n):
            c_expected[c_base + row * spec.ldc + column] = (
                golden[row][column] & 0xFFFFFFFF
            )

    stall_seed = ((derived_seed >> 32) ^ derived_seed) & 0xFFFFFFFF
    if stall_seed == 0:
        stall_seed = 1

    config = [
        master_seed & 0xFFFFFFFF,
        case_index,
        spec.m,
        spec.k,
        spec.n,
        spec.lda,
        spec.ldb,
        spec.ldc,
        len(instructions) + 1,
        a_base,
        a_words,
        b_base,
        b_words,
        c_base,
        c_words,
        stall_seed,
    ]

    case_directory.mkdir(parents=True, exist_ok=True)
    write_hex(case_directory / "config.hex", config, 8)
    write_hex(case_directory / "program.hex", encoded_program, 32)
    write_hex(case_directory / "a.hex", a_storage, 8)
    write_hex(case_directory / "b.hex", b_storage, 8)
    write_hex(case_directory / "c_initial.hex", c_initial, 8)
    write_hex(case_directory / "c_expected.hex", c_expected, 8)

    manifest: dict[str, object] = {
        "master_seed": master_seed,
        "master_seed_hex": f"0x{master_seed:08x}",
        "case_index": case_index,
        "case_seed": derived_seed,
        "case_seed_hex": f"0x{derived_seed:016x}",
        "shape": {"M": spec.m, "K": spec.k, "N": spec.n},
        "strides": {"lda": spec.lda, "ldb": spec.ldb, "ldc": spec.ldc},
        "bases": {"A": a_base, "B": b_base, "C": c_base},
        "transfer_words": {"A": a_words, "B": b_words, "C": c_words},
        "boundary_heavy": spec.boundary_heavy,
        "matrix_a": matrix_a,
        "matrix_b": matrix_b,
        "golden_c": golden,
        "instructions": [
            {
                "pc": pc,
                "encoded": f"{instruction.encode():032x}",
                **asdict(instruction),
            }
            for pc, instruction in enumerate(instructions)
        ]
        + [{"pc": len(instructions), "opcode": "HALT"}],
    }
    with (case_directory / "case.json").open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    return manifest


def resolve_executable(command: str) -> str:
    resolved = shutil.which(command)
    if resolved is None:
        raise RuntimeError(f"required executable not found: {command}")
    return resolved


def compile_testbench(iverilog: str, output_path: Path) -> None:
    command = [
        iverilog,
        "-g2012",
        "-Wall",
        "-Wno-sensitivity-entire-array",
        "-s",
        "tb_randomized_differential",
        "-o",
        str(output_path),
        "rtl/systolic_pe.sv",
        "rtl/systolic_array.sv",
        "rtl/systolicforge_sdp_ram.sv",
        "rtl/systolicforge_npu.sv",
        "rtl/scratchpad_dma.sv",
        "rtl/systolicforge_soc.sv",
        "tb/tb_randomized_differential.sv",
    ]
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "random differential testbench compilation failed:\n" + result.stdout
        )
    if result.stdout.strip():
        print(result.stdout.rstrip())


def run_case(
    vvp: str,
    simulation_image: Path,
    case_directory: Path,
) -> tuple[bool, str]:
    result = subprocess.run(
        [vvp, str(simulation_image)],
        cwd=case_directory,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    output = result.stdout
    (case_directory / "simulation.log").write_text(output, encoding="utf-8")
    passed = result.returncode == 0 and "PASS:" in output and "FAIL:" not in output
    return passed, output


def coverage_summary(manifests: Sequence[dict[str, object]]) -> dict[str, object]:
    shapes = [manifest["shape"] for manifest in manifests]
    strides = [manifest["strides"] for manifest in manifests]
    return {
        "case_count": len(manifests),
        "unique_shapes": len(
            {
                (shape["M"], shape["K"], shape["N"])
                for shape in shapes
            }
        ),
        "partial_k_tiles": any(shape["K"] % ARRAY_ROWS != 0 for shape in shapes),
        "partial_n_tiles": any(shape["N"] % ARRAY_COLS != 0 for shape in shapes),
        "k_accumulation": any(shape["K"] > ARRAY_ROWS for shape in shapes),
        "multi_n_tiles": any(shape["N"] > ARRAY_COLS for shape in shapes),
        "padded_strides": any(
            stride["lda"] > shape["K"]
            or stride["ldb"] > shape["N"]
            or stride["ldc"] > shape["N"]
            for shape, stride in zip(shapes, strides)
        ),
        "boundary_heavy_cases": sum(
            bool(manifest["boundary_heavy"]) for manifest in manifests
        ),
        "memory_backpressure": "forced first read/write stall plus seeded LFSR",
    }


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Compare randomized strided signed MatMul cases against the "
            "integrated SystolicForge SoC RTL"
        )
    )
    parser.add_argument(
        "--seed",
        type=parse_integer,
        default=DEFAULT_SEED,
        help=f"master seed in decimal or hex (default: 0x{DEFAULT_SEED:08x})",
    )
    parser.add_argument(
        "--cases",
        type=int,
        default=DEFAULT_CASES,
        help=f"number of cases (default: {DEFAULT_CASES})",
    )
    parser.add_argument(
        "--case-index",
        type=int,
        help="run only this case index for exact failure reproduction",
    )
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=Path("build/randomized_differential"),
        help="artifact directory relative to the repository root",
    )
    parser.add_argument(
        "--iverilog",
        default=os.environ.get("IVERILOG", "iverilog"),
        help="Icarus Verilog compiler executable",
    )
    parser.add_argument(
        "--vvp",
        default=os.environ.get("VVP", "vvp"),
        help="Icarus Verilog runtime executable",
    )
    return parser


def main() -> int:
    args = build_argument_parser().parse_args()
    if args.cases <= 0:
        print("error: --cases must be positive", file=sys.stderr)
        return 2
    if args.case_index is not None and args.case_index < 0:
        print("error: --case-index must be non-negative", file=sys.stderr)
        return 2

    try:
        iverilog = resolve_executable(args.iverilog)
        vvp = resolve_executable(args.vvp)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    build_directory = args.build_dir
    if not build_directory.is_absolute():
        build_directory = REPO_ROOT / build_directory
    build_directory = build_directory.resolve()
    build_directory.mkdir(parents=True, exist_ok=True)
    simulation_image = build_directory / "randomized_differential.vvp"

    try:
        compile_testbench(iverilog, simulation_image)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    indices = (
        [args.case_index]
        if args.case_index is not None
        else list(range(args.cases))
    )
    seed_directory = build_directory / f"seed_{args.seed:08x}"
    seed_directory.mkdir(parents=True, exist_ok=True)
    manifests: list[dict[str, object]] = []

    print(
        f"randomized differential regression: seed=0x{args.seed:08x}, "
        f"cases={len(indices)}"
    )
    for index in indices:
        spec = build_case_spec(args.seed, index)
        case_directory = seed_directory / (
            f"case_{index:03d}_{spec.m}x{spec.k}x{spec.n}"
        )
        case_directory.mkdir(parents=True, exist_ok=True)
        manifest: dict[str, object] | None = None
        try:
            manifest = generate_case(args.seed, index, case_directory)
            passed, output = run_case(vvp, simulation_image, case_directory)
        except (OSError, RuntimeError, ValueError) as exc:
            passed = False
            output = f"harness error: {exc}\n"
            (case_directory / "simulation.log").write_text(
                output, encoding="utf-8"
            )
        manifests.append(
            manifest
            if manifest is not None
            else {
                "case_index": index,
                "shape": {"M": spec.m, "K": spec.k, "N": spec.n},
                "strides": {
                    "lda": spec.lda,
                    "ldb": spec.ldb,
                    "ldc": spec.ldc,
                },
                "boundary_heavy": spec.boundary_heavy,
            }
        )

        if not passed:
            failure = {
                "master_seed": args.seed,
                "master_seed_hex": f"0x{args.seed:08x}",
                "case_index": index,
                "artifact_directory": str(case_directory),
                "reproduce": (
                    "python scripts/run_randomized_differential.py "
                    f"--seed 0x{args.seed:x} --case-index {index}"
                ),
            }
            with (seed_directory / "FAILURE.json").open(
                "w", encoding="utf-8"
            ) as stream:
                json.dump(failure, stream, indent=2)
                stream.write("\n")
            print(output.rstrip())
            print(
                "FAILED: artifacts preserved at "
                f"{case_directory}\nReproduce with: {failure['reproduce']}",
                file=sys.stderr,
            )
            return 1

        pass_line = next(
            (line for line in output.splitlines() if line.startswith("PASS:")),
            f"PASS: case={index}",
        )
        print(pass_line)

    coverage = coverage_summary(manifests)
    if args.case_index is None and args.cases >= len(DIRECTED_CASES):
        required_coverage = (
            "partial_k_tiles",
            "partial_n_tiles",
            "k_accumulation",
            "multi_n_tiles",
            "padded_strides",
        )
        missing = [name for name in required_coverage if not coverage[name]]
        if missing:
            print(
                "error: generated suite missed required coverage: "
                + ", ".join(missing),
                file=sys.stderr,
            )
            return 1

    summary = {
        "master_seed": args.seed,
        "master_seed_hex": f"0x{args.seed:08x}",
        "case_indices": indices,
        "coverage": coverage,
        "result": "PASS",
    }
    with (seed_directory / "summary.json").open("w", encoding="utf-8") as stream:
        json.dump(summary, stream, indent=2)
        stream.write("\n")

    print(
        "PASS: randomized differential verification completed "
        f"{len(indices)} case(s); artifacts: {seed_directory}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
