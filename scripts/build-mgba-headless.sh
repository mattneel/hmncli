#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="$repo_root/.zig-cache/mgba-oracle"
src_dir="$cache_root/src"
build_dir="$cache_root/build"
patch_path="$repo_root/scripts/patches/mgba-headless-video-buffer.patch"

repo_url="https://github.com/mgba-emu/mgba.git"
repo_commit="f8082d31fb3ef6af15226e74229d6a5aaec526c6"
binary_path="$build_dir/mgba-headless"

if [ ! -f "$patch_path" ]; then
  echo "missing mGBA patch at $patch_path" >&2
  exit 1
fi

mkdir -p "$cache_root"

if [ ! -d "$src_dir/.git" ]; then
  git clone "$repo_url" "$src_dir" >&2
fi

git -C "$src_dir" fetch --quiet origin
git -C "$src_dir" checkout --detach --force "$repo_commit" >/dev/null
git -C "$src_dir" reset --hard "$repo_commit" >/dev/null
git -C "$src_dir" clean -fdx >/dev/null
git -C "$src_dir" apply "$patch_path"

rm -rf "$build_dir"
mkdir -p "$build_dir"

cd "$build_dir"
/usr/bin/cmake ../src \
  -DBUILD_HEADLESS=ON \
  -DBUILD_SDL=OFF \
  -DBUILD_QT=OFF \
  -DBUILD_TEST=OFF \
  -DBUILD_CINEMA=OFF \
  -DBUILD_DOCGEN=OFF \
  -DBUILD_EXAMPLE=OFF \
  -DBUILD_PYTHON=OFF \
  -DBUILD_PERF=OFF \
  -DUSE_SQLITE3=OFF \
  -DUSE_LIBZIP=OFF \
  -DUSE_MINIZIP=OFF \
  -DUSE_ZLIB=ON \
  -DUSE_PNG=ON \
  -DENABLE_SCRIPTING=ON \
  -DUSE_LUA=5.4 \
  -DBUILD_GLES2=OFF \
  -DBUILD_GLES3=OFF \
  -DBUILD_GL=OFF >&2

/usr/bin/cmake --build . --target mgba-headless -j"$(nproc 2>/dev/null || echo 4)" >&2

printf '%s\n' "$binary_path"
