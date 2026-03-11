#!/usr/bin/env python3
"""Summarize final coverage means by protocol/implementation and fuzzer.

This script scans CSV files in a directory, parses metadata from file names
(e.g., protocol, implementation, fuzzer), then computes the average of the
last-row coverage metric for each (protocol, implementation, fuzzer) group.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def normalize_stem(filename: str) -> str:
    if filename.endswith(".coverage.csv"):
        return filename[: -len(".coverage.csv")]
    if filename.endswith("-coverage.csv"):
        return filename[: -len("-coverage.csv")]
    if filename.endswith(".csv"):
        return filename[: -len(".csv")]
    return filename


def parse_name(file_name: str) -> Optional[Tuple[str, str, str]]:
    """Parse (protocol, impl, fuzzer) from a coverage csv file name."""
    stem = normalize_stem(file_name)
    parts = stem.split("-")

    if len(parts) < 5 or parts[0] != "pingu":
        return None

    fuzzer = parts[1]
    protocol = parts[2]

    # Implementation may contain '-' and sits between protocol and run index.
    impl_tokens: List[str] = []
    for token in parts[3:]:
        if token.isdigit():
            break
        impl_tokens.append(token)

    if not impl_tokens:
        return None

    impl = "-".join(impl_tokens)
    return protocol, impl, fuzzer


def read_last_metric(csv_path: Path, metric: str) -> Optional[float]:
    last_row: Optional[Dict[str, str]] = None
    with csv_path.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row:
                last_row = row

    if not last_row:
        return None
    if metric not in last_row or last_row[metric] in (None, ""):
        return None

    try:
        return float(last_row[metric])
    except ValueError:
        return None


def build_markdown_table(
    grouped_mean: Dict[Tuple[str, str], Dict[str, float]], fuzzers: List[str], metric: str
) -> str:
    lines: List[str] = []
    header = ["Protocol-Impl", *fuzzers]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")

    for protocol, impl in sorted(grouped_mean.keys()):
        row_key = f"{protocol}/{impl}"
        row_vals = []
        for fuzzer in fuzzers:
            val = grouped_mean[(protocol, impl)].get(fuzzer)
            row_vals.append("-" if val is None else format_metric_value(val, metric))
        lines.append("| " + " | ".join([row_key, *row_vals]) + " |")

    lines.append("")
    lines.append(f"metric = {metric}")
    return "\n".join(lines)


def latex_escape(text: str) -> str:
    return text.replace("_", r"\_")


def build_latex_table(
    grouped_mean: Dict[Tuple[str, str], Dict[str, float]], fuzzers: List[str], metric: str
) -> str:
    col_spec = "l" + "r" * len(fuzzers)
    lines: List[str] = []
    lines.append(r"\begin{tabular}{" + col_spec + "}")
    lines.append(r"\hline")
    header = ["Protocol/Impl", *fuzzers]
    lines.append(" & ".join(latex_escape(x) for x in header) + r" \\")
    lines.append(r"\hline")

    for protocol, impl in sorted(grouped_mean.keys()):
        row_key = f"{protocol}/{impl}"
        row_vals = []
        for fuzzer in fuzzers:
            val = grouped_mean[(protocol, impl)].get(fuzzer)
            row_vals.append("-" if val is None else format_metric_value(val, metric))
        lines.append(
            " & ".join([latex_escape(row_key), *(latex_escape(v) for v in row_vals)]) + r" \\"
        )

    lines.append(r"\hline")
    lines.append(r"\end{tabular}")
    lines.append("% metric = " + metric)
    return "\n".join(lines)


def format_metric_value(value: float, metric: str) -> str:
    if metric in {"l_abs", "b_abs"}:
        return str(int(round(value)))
    return f"{value:.4f}"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compute final coverage mean table by protocol/impl and fuzzer."
    )
    parser.add_argument(
        "directory",
        nargs="?",
        type=Path,
        help="Directory containing coverage csv files (legacy positional arg)",
    )
    parser.add_argument(
        "--input-dir",
        dest="input_dir",
        type=Path,
        default=None,
        help="Directory containing coverage csv files",
    )
    parser.add_argument(
        "--metric",
        default="l_per",
        help="Coverage metric column to use (default: l_per)",
    )
    parser.add_argument(
        "--format",
        dest="table_format",
        choices=["md", "latex"],
        default="md",
        help="Output table format: md or latex (default: md)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Optional output file path",
    )
    args = parser.parse_args()

    data_dir = args.input_dir or args.directory
    if data_dir is None:
        raise SystemExit("Please provide input directory via --input-dir or positional directory")
    if not data_dir.is_dir():
        raise SystemExit(f"Directory not found: {data_dir}")

    values: Dict[Tuple[str, str, str], List[float]] = {}
    csv_files = sorted(data_dir.glob("*.csv"))

    for csv_path in csv_files:
        parsed = parse_name(csv_path.name)
        if parsed is None:
            continue

        protocol, impl, fuzzer = parsed
        val = read_last_metric(csv_path, args.metric)
        if val is None:
            continue

        values.setdefault((protocol, impl, fuzzer), []).append(val)

    if not values:
        raise SystemExit(
            "No valid data found. Check file naming pattern and metric column name."
        )

    fuzzers = sorted({fuzzer for _, _, fuzzer in values.keys()})

    grouped_mean: Dict[Tuple[str, str], Dict[str, float]] = {}
    for protocol, impl, fuzzer in values:
        key = (protocol, impl)
        grouped_mean.setdefault(key, {})
        series = values[(protocol, impl, fuzzer)]
        grouped_mean[key][fuzzer] = sum(series) / len(series)

    if args.table_format == "latex":
        table = build_latex_table(grouped_mean, fuzzers, args.metric)
    else:
        table = build_markdown_table(grouped_mean, fuzzers, args.metric)

    if args.output:
        args.output.write_text(table + "\n", encoding="utf-8")

    print(table)


if __name__ == "__main__":
    main()
