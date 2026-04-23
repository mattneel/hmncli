#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/synthetic/vblank"

arm-none-eabi-as -mcpu=arm7tdmi -o "$fixture_dir/frame_irq.o" "$fixture_dir/frame_irq.s"
arm-none-eabi-ld -Ttext=0x08000000 -nostdlib -o "$fixture_dir/frame_irq.elf" "$fixture_dir/frame_irq.o"
arm-none-eabi-objcopy -O binary "$fixture_dir/frame_irq.elf" "$fixture_dir/frame_irq.gba"

rm -f "$fixture_dir/frame_irq.o" "$fixture_dir/frame_irq.elf"

wc -c "$fixture_dir/frame_irq.gba"
sha256sum "$fixture_dir/frame_irq.gba"
