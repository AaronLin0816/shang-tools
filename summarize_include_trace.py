#!/usr/bin/env python3
import argparse
import csv
import os
from collections import Counter, defaultdict
from pathlib import Path


def normalize_header(raw: str) -> str:
    header = raw.strip()
    if not header:
        return ""
    if header.startswith("./"):
        header = os.path.abspath(header)
    return os.path.normpath(header)


def read_meta(path: Path) -> dict[str, str]:
    meta_path = path.with_suffix(".meta")
    meta: dict[str, str] = {}
    if not meta_path.exists():
        return meta
    for line in meta_path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            meta[key] = value
    return meta


def file_size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def rel(path: str, root: Path) -> str:
    try:
        return str(Path(path).resolve().relative_to(root))
    except Exception:
        return path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Summarize compiler -H include traces captured by include_trace_launcher.sh."
    )
    parser.add_argument("trace_dir", type=Path)
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--csv", dest="csv_path", type=Path, default=None)
    parser.add_argument("--top", type=int, default=50)
    parser.add_argument(
        "--project-only",
        action="store_true",
        help="Only include headers under --source-root.",
    )
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    trace_dir = args.trace_dir.resolve()
    header_logs = sorted(trace_dir.glob("*.headers"))

    total = Counter()
    units = defaultdict(set)
    unit_sources: dict[str, str] = {}

    for header_log in header_logs:
        unit_id = header_log.stem
        meta = read_meta(header_log)
        unit_sources[unit_id] = meta.get("source", "")
        seen_in_unit = set()
        for raw in header_log.read_text(errors="replace").splitlines():
            header = normalize_header(raw)
            if not header:
                continue
            if args.project_only:
                try:
                    Path(header).resolve().relative_to(source_root)
                except Exception:
                    continue
            total[header] += 1
            seen_in_unit.add(header)
        for header in seen_in_unit:
            units[header].add(unit_id)

    rows = []
    for header, include_count in total.items():
        size = file_size(header)
        unit_count = len(units[header])
        rows.append(
            {
                "header": header,
                "display": rel(header, source_root),
                "include_count": include_count,
                "translation_units": unit_count,
                "size_bytes": size,
                "size_kib": size / 1024,
                "expanded_kib": include_count * size / 1024,
            }
        )

    rows.sort(
        key=lambda row: (
            row["include_count"],
            row["translation_units"],
            row["expanded_kib"],
            row["size_bytes"],
        ),
        reverse=True,
    )

    report_path = args.report or trace_dir / "include_trace_report.md"
    csv_path = args.csv_path or trace_dir / "include_trace_summary.csv"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "header",
                "include_count",
                "translation_units",
                "size_bytes",
                "expanded_kib",
            ],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "header": row["header"],
                    "include_count": row["include_count"],
                    "translation_units": row["translation_units"],
                    "size_bytes": row["size_bytes"],
                    "expanded_kib": f"{row['expanded_kib']:.1f}",
                }
            )

    top_rows = rows[: args.top]
    bulky_rows = sorted(
        rows,
        key=lambda row: (
            row["translation_units"],
            row["expanded_kib"],
            row["size_bytes"],
            row["include_count"],
        ),
        reverse=True,
    )[:2]

    lines = [
        "# Include Trace Report",
        "",
        f"- Trace directory: `{trace_dir}`",
        f"- Header logs: `{len(header_logs)}`",
        f"- Unique headers: `{len(rows)}`",
        f"- Source root: `{source_root}`",
        f"- CSV: `{csv_path}`",
        "",
        "## Two Massively Included Bulky Headers",
        "",
        "|Rank|Header|Total includes|Translation units|Header size KiB|Estimated expanded KiB|",
        "|---:|---|---:|---:|---:|---:|",
    ]
    for idx, row in enumerate(bulky_rows, 1):
        lines.append(
            f"|{idx}|`{row['display']}`|{row['include_count']}|{row['translation_units']}|"
            f"{row['size_kib']:.1f}|{row['expanded_kib']:.1f}|"
        )

    lines.extend(
        [
            "",
            "## Top Included Headers",
            "",
            "|Rank|Header|Total includes|Translation units|Header size KiB|Estimated expanded KiB|",
            "|---:|---|---:|---:|---:|---:|",
        ]
    )
    for idx, row in enumerate(top_rows, 1):
        lines.append(
            f"|{idx}|`{row['display']}`|{row['include_count']}|{row['translation_units']}|"
            f"{row['size_kib']:.1f}|{row['expanded_kib']:.1f}|"
        )

    lines.extend(
        [
            "",
            "## Method",
            "",
            "CMake used `include_trace_launcher.sh` as `CMAKE_C_COMPILER_LAUNCHER` and "
            "`CMAKE_CXX_COMPILER_LAUNCHER`. The launcher invokes the real compiler with "
            "`-H`, stores include lines from each compilation unit, and lets diagnostics "
            "continue to stderr. This report counts every `-H` include event and also "
            "tracks how many translation units included each header at least once.",
            "",
            "The estimated expanded KiB metric is `total includes * header file size`; it "
            "is a rough pressure indicator, not a preprocessor token count.",
            "",
        ]
    )
    report_path.write_text("\n".join(lines))

    print(f"Wrote {report_path}")
    print(f"Wrote {csv_path}")
    if bulky_rows:
        print("Top bulky headers:")
        for row in bulky_rows:
            print(
                f"{row['display']}: includes={row['include_count']} "
                f"units={row['translation_units']} size_kib={row['size_kib']:.1f} "
                f"expanded_kib={row['expanded_kib']:.1f}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
