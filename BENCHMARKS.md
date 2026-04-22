# Benchmarks

This file tracks internal performance baselines for `hmncli`.

These numbers are for regression tracking inside this repo. They are not emulator shootout numbers and they are not claims about real-game FPS.

## Methodology

- Workload: `tests/fixtures/bench/arm-tight-loop.gba`
- Source: `tests/fixtures/bench/arm-tight-loop.s`
- Runner: `scripts/bench_arm_tight_loop.py`
- Retired target: `10_000_000` guest instructions
- Samples: `20`
- Metric: guest IPS = retired guest instructions / wall-clock time
- Counter model: retired counts are prepaid once per straight-line guest block, with a per-instruction fallback when execution can stop mid-block
- Toolchain: Zig `0.17.0-dev.56+a8226cd53`
- Build modes compared: `hmncli build --opt debug|release`
- Command:

```bash
scripts/bench_arm_tight_loop.py --retired 10000000 --samples 20
```

## Host

- CPU: `AMD Ryzen 9 9955HX3D 16-Core Processor`
- OS: `Linux 6.6.87.2-microsoft-standard-WSL2`
- Architecture: `x86_64`
- Virtualization: `WSL2`

## Baseline

Measured on `2026-04-22` against the code at commit `5bf472f`.

| Workload | Opt | Retired | Samples | Mean | Min | Max | Guest IPS | Real-GBA Multiple |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `arm-tight-loop.gba` | `debug` | 10,000,000 | 20 | 0.014994s | 0.014772s | 0.015589s | 666,945,185 | 39.7x |
| `arm-tight-loop.gba` | `release` | 10,000,000 | 20 | 0.002825s | 0.002601s | 0.004032s | 3,539,898,821 | 211.0x |

Real-GBA multiple uses a nominal `16.78 MHz` ARM7TDMI instruction rate as a rough reference point, not a cycle-accurate comparison.

## Interpretation

- This is a synthetic tight-loop benchmark, not a representative game workload.
- The `release` result shows that lifted ARM code can execute at effectively native host throughput on a straight-line ALU-heavy loop.
- The `debug` to `release` ratio here is about `5.3x`.
- Future benchmark entries should record the exact command, host, sample count, and commit they came from.
- If benchmark methodology changes, add a new section instead of silently rewriting older baselines.
