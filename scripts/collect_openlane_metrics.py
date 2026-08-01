#!/usr/bin/env python3
"""Turn the newest OpenLane metrics.json into a small reviewable Markdown table."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


METRICS = {
    "Standard-cell area": ("design__instance__area", "design__instance__area__stdcell"),
    "Core area": ("design__core__area",),
    "Core utilization": ("design__instance__utilization",),
    "Setup WNS": ("timing__setup__ws", "timing__setup__wns"),
    "Setup TNS": ("timing__setup__tns",),
    "Total power": ("power__total",),
    "DRC errors": ("magic__drc_error__count", "design__violations"),
}


def newest_metrics(run_root: Path) -> Path:
    candidates = list(run_root.rglob("metrics.json"))
    if not candidates:
        raise FileNotFoundError(f"no metrics.json found below {run_root}")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def first_present(metrics: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in metrics:
            return metrics[key]
    return "not reported"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_root", type=Path, help="OpenLane run directory")
    parser.add_argument("-o", "--output", type=Path, default=Path("pd/metrics.md"))
    args = parser.parse_args()

    try:
        metrics_path = newest_metrics(args.run_root)
        metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}")
        return 2

    lines = [
        "# Sky130 implementation metrics",
        "",
        f"Source: `{metrics_path}`",
        "",
        "| Metric | Value |",
        "|---|---:|",
    ]
    for label, keys in METRICS.items():
        lines.append(f"| {label} | {first_present(metrics, keys)} |")
    lines.append("")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
