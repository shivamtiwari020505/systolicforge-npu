#!/usr/bin/env python3
"""Render compact SVG evidence from SystolicForge Icarus VCD traces.

The renderer intentionally uses only the Python standard library.  It samples
registered behavior on falling clock edges, after the DUT's positive-edge
nonblocking assignments have settled.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import html
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Signal:
    width: int
    names: list[str] = field(default_factory=list)
    times: list[int] = field(default_factory=list)
    values: list[str] = field(default_factory=list)

    def append(self, time: int, value: str) -> None:
        value = value.lower()
        if self.times and self.times[-1] == time:
            self.values[-1] = value
        elif not self.values or self.values[-1] != value:
            self.times.append(time)
            self.values.append(value)

    def at(self, time: int) -> str:
        index = bisect.bisect_right(self.times, time) - 1
        return self.values[index] if index >= 0 else "x"


class VcdTrace:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.signals: dict[str, Signal] = {}
        self.names: dict[str, str] = {}
        self._parse()

    def _parse(self) -> None:
        scope: list[str] = []
        current_time = 0
        in_definitions = True

        with self.path.open("r", encoding="ascii", errors="replace") as stream:
            for raw_line in stream:
                line = raw_line.strip()
                if not line:
                    continue

                if in_definitions:
                    if line.startswith("$scope"):
                        scope.append(line.split()[2])
                    elif line.startswith("$upscope"):
                        scope.pop()
                    elif line.startswith("$var"):
                        fields = line.split()
                        width = int(fields[2])
                        identifier = fields[3]
                        reference = fields[4]
                        full_name = ".".join([*scope, reference])
                        signal = self.signals.setdefault(identifier, Signal(width=width))
                        signal.names.append(full_name)
                        self.names[full_name] = identifier
                    elif line.startswith("$enddefinitions"):
                        in_definitions = False
                    continue

                if line.startswith("#"):
                    current_time = int(line[1:])
                elif line[0] in "01xzXZ":
                    self.signals[line[1:]].append(current_time, line[0])
                elif line[0] in "bB":
                    value, identifier = line[1:].split(None, 1)
                    self.signals[identifier].append(current_time, value)

    def signal(self, suffix: str, scope_hint: str) -> Signal:
        matches = [
            (name, identifier)
            for name, identifier in self.names.items()
            if (name == suffix or name.endswith("." + suffix)) and scope_hint in name
        ]
        if not matches:
            available = ", ".join(sorted(self.names))
            raise KeyError(f"signal {suffix!r} not found in {self.path}; available: {available}")
        matches.sort(key=lambda item: (item[0].count("."), len(item[0])))
        return self.signals[matches[0][1]]

    def falling_edges(self, clock: Signal) -> list[int]:
        edges: list[int] = []
        previous = "x"
        for time, value in zip(clock.times, clock.values):
            if previous == "1" and value == "0":
                edges.append(time)
            previous = value
        return edges


def logic_high(value: str) -> bool:
    return value == "1"


def binary_to_int(value: str) -> int | None:
    if not value or any(bit not in "01" for bit in value):
        return None
    return int(value, 2)


def semantic_trace_hash(signals: dict[str, Signal]) -> str:
    """Hash named signal transitions while ignoring non-semantic VCD headers."""
    digest = hashlib.sha256()
    for name in sorted(signals):
        signal = signals[name]
        digest.update(f"{name}:{signal.width}\n".encode("ascii"))
        for time, value in zip(signal.times, signal.values):
            digest.update(f"{time}:{value}\n".encode("ascii"))
    return digest.hexdigest()


def bus_binary(value: str, width: int) -> str:
    if any(bit not in "01" for bit in value):
        return value.upper()
    return "0b" + value.zfill(width)


def bus_decimal(value: str, _width: int) -> str:
    number = binary_to_int(value)
    return "X" if number is None else str(number)


STATE_NAMES = {
    0: "IDLE",
    1: "FETCH",
    2: "DECODE",
    3: "W_REQ",
    4: "W_WAIT",
    5: "LOAD_W",
    6: "A_WAIT",
    7: "ISSUE",
    8: "DRAIN",
}


def state_name(value: str, _width: int) -> str:
    number = binary_to_int(value)
    return STATE_NAMES.get(number, "X" if number is None else str(number))


def svg_text(x: float, y: float, value: str, css_class: str, anchor: str = "start") -> str:
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" class="{css_class}" '
        f'text-anchor="{anchor}">{html.escape(value)}</text>'
    )


def render_waveform(
    output_path: Path,
    title: str,
    subtitle: str,
    source_hash: str,
    cycle_times: list[int],
    lanes: list[tuple[str, str, list[str], object]],
) -> None:
    left = 178
    cycle_width = 42
    top = 104
    lane_height = 48
    plot_width = cycle_width * len(cycle_times)
    width = left + plot_width + 28
    height = top + lane_height * len(lanes) + 70

    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        f"<title id=\"title\">{html.escape(title)}</title>",
        f"<desc id=\"desc\">{html.escape(subtitle)} Generated from canonical trace SHA-256 {source_hash}.</desc>",
        "<style>",
        "  .title { font: 700 21px Arial, sans-serif; fill: #0f172a; }",
        "  .subtitle { font: 12px Arial, sans-serif; fill: #475569; }",
        "  .label { font: 600 12px Consolas, monospace; fill: #0f172a; }",
        "  .cycle { font: 10px Consolas, monospace; fill: #64748b; }",
        "  .bus { font: 600 10px Consolas, monospace; fill: #0f172a; }",
        "  .foot { font: 10px Consolas, monospace; fill: #64748b; }",
        "</style>",
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        svg_text(20, 32, title, "title"),
        svg_text(20, 53, subtitle, "subtitle"),
    ]

    for index in range(len(cycle_times) + 1):
        x = left + index * cycle_width
        lines.append(
            f'<line x1="{x}" y1="{top - 18}" x2="{x}" y2="{top + lane_height * len(lanes)}" '
            'stroke="#e2e8f0" stroke-width="1"/>'
        )
        if index < len(cycle_times):
            lines.append(svg_text(x + cycle_width / 2, top - 25, f"C{index}", "cycle", "middle"))

    for lane_index, (label, kind, values, formatter) in enumerate(lanes):
        row_y = top + lane_index * lane_height
        if lane_index % 2:
            lines.append(
                f'<rect x="8" y="{row_y}" width="{width - 16}" height="{lane_height}" fill="#f8fafc"/>'
            )
        lines.append(svg_text(18, row_y + 29, label, "label"))

        if kind == "clock":
            high_y = row_y + 10
            low_y = row_y + 35
            path: list[str] = []
            for cycle in range(len(values)):
                x0 = left + cycle * cycle_width
                xm = x0 + cycle_width / 2
                x1 = x0 + cycle_width
                path.append(f"M {x0} {low_y} H {xm} V {high_y} H {x1} V {low_y}")
            lines.append(f'<path d="{" ".join(path)}" fill="none" stroke="#334155" stroke-width="2"/>')
        elif kind == "bit":
            high_y = row_y + 10
            low_y = row_y + 35
            path = []
            previous_y: float | None = None
            for cycle, value in enumerate(values):
                x0 = left + cycle * cycle_width
                x1 = x0 + cycle_width
                y = high_y if logic_high(value) else low_y
                if previous_y is None:
                    path.append(f"M {x0} {y}")
                elif previous_y != y:
                    path.append(f"V {y}")
                path.append(f"H {x1}")
                previous_y = y
            lines.append(f'<path d="{" ".join(path)}" fill="none" stroke="#0f766e" stroke-width="2.2"/>')
        elif kind == "bus":
            start = 0
            while start < len(values):
                end = start + 1
                while end < len(values) and values[end] == values[start]:
                    end += 1
                x = left + start * cycle_width + 1
                box_width = (end - start) * cycle_width - 2
                fill = "#eff6ff" if start % 2 == 0 else "#ecfeff"
                lines.append(
                    f'<rect x="{x}" y="{row_y + 7}" width="{box_width}" height="31" rx="5" '
                    f'fill="{fill}" stroke="#2563eb"/>'
                )
                text_value = formatter(values[start], 1)
                if box_width >= 22:
                    lines.append(svg_text(x + box_width / 2, row_y + 27, text_value, "bus", "middle"))
                start = end

    hash_label = f"source: {source_hash[:16]}…  •  falling-edge samples  •  generated by scripts/render_waveforms.py"
    lines.append(svg_text(20, height - 22, hash_label, "foot"))
    lines.append("</svg>")
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def render_array(trace_path: Path, output_dir: Path) -> tuple[str, int]:
    trace = VcdTrace(trace_path)
    scope = "tb_systolic_array"
    signals = {
        "clk": trace.signal("clk", scope),
        "rst_n": trace.signal("rst_n", scope),
        "weight_load": trace.signal("weight_load", scope),
        "input_valid": trace.signal("input_valid", scope),
        "output_valid": trace.signal("output_valid", scope),
    }
    edges = trace.falling_edges(signals["clk"])
    weight_values = [signals["weight_load"].at(time) for time in edges]
    output_values = [signals["output_valid"].at(time) for time in edges]
    first_weight = next(index for index, value in enumerate(weight_values) if value == "1")
    last_output = max(index for index, value in enumerate(output_values) if binary_to_int(value) not in (None, 0))
    selected = edges[max(0, first_weight - 1): min(len(edges), last_output + 3)]
    digest = semantic_trace_hash(signals)

    values = {name: [signal.at(time) for time in selected] for name, signal in signals.items()}
    lanes = [
        ("clk", "clock", values["clk"], None),
        ("rst_n", "bit", values["rst_n"], None),
        ("weight_load", "bit", values["weight_load"], None),
        ("input_valid", "bit", values["input_valid"], None),
        ("output_valid[3:0]", "bus", values["output_valid"], lambda value, _width: bus_binary(value, 4)),
    ]
    render_waveform(
        output_dir / "systolic_array_waveform.svg",
        "Measured systolic-array wavefront",
        "4×4 RTL test: one weight-load pulse, six A rows, one injected valid bubble, staggered column drain",
        digest,
        selected,
        lanes,
    )
    return digest, len(selected)


def render_npu(trace_path: Path, output_dir: Path) -> tuple[str, int, int]:
    trace = VcdTrace(trace_path)
    scope = "tb_systolicforge_npu"
    signals = {
        "clk": trace.signal("clk", scope),
        "start": trace.signal("start", scope),
        "busy": trace.signal("busy", scope),
        "done": trace.signal("done", scope),
        "fault": trace.signal("fault", scope),
        "pc": trace.signal("pc_debug", scope),
        "state": trace.signal("state_q", scope),
        "weight_load": trace.signal("weight_load", scope),
        "array_input_valid": trace.signal("array_input_valid", scope),
        "array_output_valid": trace.signal("array_output_valid", scope),
        "issue_row": trace.signal("issue_row_q", scope),
    }
    edges = trace.falling_edges(signals["clk"])
    sampled = {name: [signal.at(time) for time in edges] for name, signal in signals.items()}

    start_index = next(
        index for index in range(1, len(edges))
        if sampled["start"][index - 1] == "1"
        and sampled["start"][index] == "0"
        and sampled["busy"][index] == "1"
    )
    done_index = next(
        index for index in range(start_index, len(edges)) if sampled["done"][index] == "1"
    )
    selected = edges[start_index:done_index + 2]
    digest = semantic_trace_hash(signals)
    values = {name: [signal.at(time) for time in selected] for name, signal in signals.items()}

    lanes = [
        ("clk", "clock", values["clk"], None),
        ("start", "bit", values["start"], None),
        ("busy", "bit", values["busy"], None),
        ("pc", "bus", values["pc"], bus_decimal),
        ("state_q", "bus", values["state"], state_name),
        ("weight_load", "bit", values["weight_load"], None),
        ("array_input_valid", "bit", values["array_input_valid"], None),
        ("issue_row_q", "bus", values["issue_row"], bus_decimal),
        ("array_output_valid[3:0]", "bus", values["array_output_valid"], lambda value, _width: bus_binary(value, 4)),
        ("fault", "bit", values["fault"], None),
        ("done", "bit", values["done"], None),
    ]
    render_waveform(
        output_dir / "npu_instruction_waveform.svg",
        "Measured mini-NPU instruction timing",
        "4×4 RTL test: two M=3, N=3 MATMUL tiles (K=4 then K=2 accumulate), followed by HALT",
        digest,
        selected,
        lanes,
    )
    return digest, len(selected), done_index - start_index


def write_evidence(
    output_dir: Path,
    array_hash: str,
    array_cycles: int,
    npu_hash: str,
    npu_cycles: int,
    done_cycle: int,
) -> None:
    content = f"""# Waveform evidence

The SVG timing diagrams in this directory are derived from Icarus Verilog VCD
output. They are not hand-authored timing claims. Regenerate the VCDs and SVGs
with:

```sh
make waveforms
```

| Rendered evidence | Testbench | Canonical signal-trace SHA-256 | Displayed samples |
|---|---|---|---:|
| `systolic_array_waveform.svg` | `tb/tb_systolic_array.sv` (4×4, M=6, one input bubble) | `{array_hash}` | {array_cycles} |
| `npu_instruction_waveform.svg` | `tb/tb_systolicforge_npu.sv` (4×4, two tiled MATMULs) | `{npu_hash}` | {npu_cycles} |

The mini-NPU testbench observes `done` {done_cycle} falling-edge sample intervals
after the start pulse is accepted. This is the same execution reported by the
self-checking simulation as {done_cycle} cycles. Sampling on falling edges shows stable
state after positive-edge sequential logic has settled.

The VCD files stay under `build/waves/` and are intentionally ignored by Git.
The hashes above cover the named signal widths, timestamps, and transitions used
by each renderer while deliberately excluding non-semantic VCD headers such as
the run date.
"""
    (output_dir / "WAVEFORM_EVIDENCE.md").write_text(content, encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vcd_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    array_hash, array_cycles = render_array(
        args.vcd_dir / "systolic_array.vcd", args.output_dir
    )
    npu_hash, npu_cycles, done_cycle = render_npu(
        args.vcd_dir / "npu_instruction.vcd", args.output_dir
    )
    write_evidence(
        args.output_dir,
        array_hash,
        array_cycles,
        npu_hash,
        npu_cycles,
        done_cycle,
    )
    print(f"rendered waveform evidence in {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
