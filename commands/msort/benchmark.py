#!/usr/bin/env python3
"""Reproducible Rust-vs-Goose msort benchmark.

Input generation and output validation happen outside the timed region.
Every measured process is pinned to the same CPU when --cpu is supplied.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from pathlib import Path


CASES = (
    ("text-key1", "key=1"),
    ("numeric-key2", "key=2n"),
    ("composite-key1-key2", "key=1@2n"),
)


def generate_input(path: Path, rows: int) -> None:
    key1_modulus = min(10_007, max(101, rows // 10))
    with path.open("wb", buffering=1024 * 1024) as output:
        block: list[bytes] = []
        for index in range(rows):
            # Deliberate duplicates make the composite case reach key 2.
            key1 = (index * 48271 + 12345) % key1_modulus
            key2 = (index * 69621 + 17) % 1_000_000
            group = (index * 97) % 997
            block.append(
                f"k{key1:07d} {key2} g{group:03d} payload_{index % 10007:05d}\n".encode()
            )
            if len(block) == 8192:
                output.write(b"".join(block))
                block.clear()
        if block:
            output.write(b"".join(block))


def command(binary: Path, key: str, input_path: Path, cpu: int | None) -> list[str]:
    base = [str(binary), key, str(input_path)]
    return ["taskset", "-c", str(cpu), *base] if cpu is not None else base


def run_once(binary: Path, key: str, input_path: Path, cpu: int | None) -> float:
    started = time.perf_counter_ns()
    completed = subprocess.run(
        command(binary, key, input_path, cpu),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    elapsed = (time.perf_counter_ns() - started) / 1_000_000.0
    if completed.returncode != 0:
        raise RuntimeError(
            f"{binary} exited {completed.returncode}: "
            f"{completed.stderr.decode(errors='replace')}"
        )
    return elapsed


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify_outputs(
    rust: Path, goose: Path, key: str, input_path: Path, work_dir: Path, cpu: int | None
) -> dict[str, object]:
    outputs = {"rust": work_dir / "rust.out", "goose": work_dir / "goose.out"}
    for name, binary in (("rust", rust), ("goose", goose)):
        with outputs[name].open("wb") as stream:
            completed = subprocess.run(
                command(binary, key, input_path, cpu),
                stdout=stream,
                stderr=subprocess.PIPE,
                check=False,
            )
        if completed.returncode != 0:
            raise RuntimeError(
                f"{name} parity run exited {completed.returncode}: "
                f"{completed.stderr.decode(errors='replace')}"
            )
    rust_hash = digest(outputs["rust"])
    goose_hash = digest(outputs["goose"])
    rust_size = outputs["rust"].stat().st_size
    goose_size = outputs["goose"].stat().st_size
    for output in outputs.values():
        output.unlink()
    if rust_hash != goose_hash or rust_size != goose_size:
        raise RuntimeError(
            f"output mismatch: rust={rust_size}:{rust_hash} "
            f"goose={goose_size}:{goose_hash}"
        )
    return {"sha256": rust_hash, "bytes": rust_size}


def summarize(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    p95_index = min(len(ordered) - 1, int(len(ordered) * 0.95))
    return {
        "median_ms": round(statistics.median(values), 3),
        "min_ms": round(min(values), 3),
        "p95_ms": round(ordered[p95_index], 3),
        "max_ms": round(max(values), 3),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=500_000)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    for binary in (args.rust, args.goose):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error(f"not an executable: {binary}")
    if args.rows <= 0 or args.warmups < 0 or args.runs <= 0:
        parser.error("rows and runs must be positive; warmups must be non-negative")

    args.work_dir.mkdir(parents=True, exist_ok=True)
    input_path = args.work_dir / "records.txt"
    generate_input(input_path, args.rows)

    report: dict[str, object] = {
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "cpu": args.cpu,
        },
        "rows": args.rows,
        "input_bytes": input_path.stat().st_size,
        "warmups": args.warmups,
        "runs": args.runs,
        "cases": [],
    }

    for case_name, key in CASES:
        parity = verify_outputs(args.rust, args.goose, key, input_path, args.work_dir, args.cpu)
        for warmup in range(args.warmups):
            order = ((args.rust, args.goose) if warmup % 2 == 0 else (args.goose, args.rust))
            for binary in order:
                run_once(binary, key, input_path, args.cpu)

        timings = {"rust": [], "goose": []}
        named = (("rust", args.rust), ("goose", args.goose))
        for round_index in range(args.runs):
            order = named if round_index % 2 == 0 else tuple(reversed(named))
            for name, binary in order:
                timings[name].append(run_once(binary, key, input_path, args.cpu))

        rust_summary = summarize(timings["rust"])
        goose_summary = summarize(timings["goose"])
        ratio = rust_summary["median_ms"] / goose_summary["median_ms"]
        report["cases"].append(
            {
                "name": case_name,
                "key": key,
                "parity": parity,
                "rust": rust_summary,
                "goose": goose_summary,
                "rust_over_goose": round(ratio, 3),
                "winner": "goose" if ratio > 1.0 else "rust",
            }
        )

    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    print(rendered, end="")
    if args.json:
        args.json.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
