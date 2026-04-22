#!/usr/bin/env bash
set -euo pipefail

if [ ! -r /etc/profile.d/devkit-env.sh ]; then
  echo "missing prerequisite: /etc/profile.d/devkit-env.sh" >&2
  exit 1
fi

for prereq in git make install sha256sum stat; do
  if ! command -v "$prereq" >/dev/null 2>&1; then
    echo "missing prerequisite: $prereq" >&2
    exit 1
  fi
done

source /etc/profile.d/devkit-env.sh

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/real/tonc"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
stage_dir="$workdir/stage"
mkdir -p "$stage_dir"

git clone https://github.com/gbadev-org/libtonc-examples.git "$workdir/libtonc-examples"
cd "$workdir/libtonc-examples"
git checkout db70fa29a0baae12c5c7603426d8535ebb5cc6ed

validate_fixture() {
  local path="$1"
  local expected_size="$2"
  local expected_sha256="$3"

  local actual_size
  actual_size="$(stat -c '%s' "$path")"
  if [ "$actual_size" != "$expected_size" ]; then
    echo "size mismatch for $(basename "$path"): expected $expected_size, got $actual_size" >&2
    exit 1
  fi

  local actual_sha256
  actual_sha256="$(sha256sum "$path" | awk '{print $1}')"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "sha256 mismatch for $(basename "$path"): expected $expected_sha256, got $actual_sha256" >&2
    exit 1
  fi
}

for demo in basic/sbb_reg basic/obj_demo basic/key_demo ext/irq_demo; do
  make -C "$demo"
  install -m 0644 "$demo/$(basename "$demo").gba" "$stage_dir/$(basename "$demo").gba"
done

validate_fixture "$stage_dir/sbb_reg.gba" 2952 7dfac2ef74f8152b69c54f6a090244a6c7e1671bf6fcd3fac36eb27abf57063d
validate_fixture "$stage_dir/obj_demo.gba" 5672 53ed8c1837e08e8345df1c59a5bf6d6d5f8bb4f55708f77891cccb2a8a46de25
validate_fixture "$stage_dir/key_demo.gba" 41736 6a4f7ae7dcd83ef63fab33a5060e81e9eeb5feb88a9ff7bf57449061b27e0f71
validate_fixture "$stage_dir/irq_demo.gba" 80724 0706b281ff79ee79f28f399652a4ac98e59d3e20a5ff2fe5f104f73fc8d9b387

mkdir -p "$fixture_dir"
install -m 0644 "$stage_dir"/*.gba "$fixture_dir"/
