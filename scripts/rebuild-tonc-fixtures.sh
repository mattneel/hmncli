#!/usr/bin/env bash
set -euo pipefail

source /etc/profile.d/devkit-env.sh

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/real/tonc"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone https://github.com/gbadev-org/libtonc-examples.git "$workdir/libtonc-examples"
cd "$workdir/libtonc-examples"
git checkout db70fa29a0baae12c5c7603426d8535ebb5cc6ed

for demo in basic/sbb_reg basic/obj_demo basic/key_demo ext/irq_demo; do
  make -C "$demo"
  cp "$demo/$(basename "$demo").gba" "$fixture_dir/$(basename "$demo").gba"
done
