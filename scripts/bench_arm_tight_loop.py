#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and time the synthetic ARM tight-loop benchmark under hmncli.",
    )
    parser.add_argument(
        "--retired",
        type=int,
        default=100_000_000,
        help="Requested retired guest instructions via --max-instructions.",
    )
    parser.add_argument(
        "--samples",
        type=int,
        default=5,
        help="Number of timing samples per optimization mode.",
    )
    parser.add_argument(
        "--target",
        default="x86_64-linux",
        help="Compilation target passed through to hmncli build.",
    )
    parser.add_argument(
        "--opt",
        action="append",
        choices=("debug", "release", "small"),
        dest="opts",
        help="Optimization mode(s) to benchmark. Defaults to debug and release.",
    )
    return parser.parse_args()


def build_binary(repo_root: Path, fixture: Path, workdir: Path, opt: str, retired: int, target: str) -> Path:
    output_path = workdir / f"arm-tight-loop-{opt}"
    command = [
        "zig",
        "build",
        "run",
        "--",
        "build",
        str(fixture),
        "--machine",
        "gba",
        "--target",
        target,
        "--output",
        "retired_count",
        "--max-instructions",
        str(retired),
        "--opt",
        opt,
        "-o",
        str(output_path),
    ]
    subprocess.run(command, cwd=repo_root, check=True)
    return output_path


def run_sample(binary: Path) -> tuple[int, float]:
    started = time.perf_counter()
    completed = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    elapsed = time.perf_counter() - started
    match = re.fullmatch(r"retired=(\d+)\n", completed.stdout)
    if match is None:
        raise RuntimeError(f"unexpected benchmark output from {binary}: {completed.stdout!r}")
    return int(match.group(1)), elapsed


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    fixture = repo_root / "tests" / "fixtures" / "bench" / "arm-tight-loop.gba"
    opt_modes = args.opts or ["debug", "release"]

    print(f"fixture: {fixture}")
    print(f"retired target: {args.retired}")
    print(f"samples: {args.samples}")
    print(f"target: {args.target}")
    print("")

    with tempfile.TemporaryDirectory(prefix="hmncli-bench-") as tempdir:
        workdir = Path(tempdir)
        for opt in opt_modes:
            binary = build_binary(repo_root, fixture, workdir, opt, args.retired, args.target)
            retired_counts: list[int] = []
            elapsed_samples: list[float] = []
            for _ in range(args.samples):
                retired, elapsed = run_sample(binary)
                retired_counts.append(retired)
                elapsed_samples.append(elapsed)

            retired = retired_counts[0]
            if any(sample != retired for sample in retired_counts):
                raise RuntimeError(f"inconsistent retired counts for {opt}: {retired_counts}")

            mean_seconds = statistics.mean(elapsed_samples)
            min_seconds = min(elapsed_samples)
            max_seconds = max(elapsed_samples)
            ips = retired / mean_seconds
            print(
                f"{opt:>7}  retired={retired:<12d}  "
                f"mean={mean_seconds:.6f}s  min={min_seconds:.6f}s  max={max_seconds:.6f}s  "
                f"ips={ips:,.0f}"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
