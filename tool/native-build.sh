#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core_dir="$project_dir/../core-go"
sdk_dir=$(mise where android-sdk@19.0)
java_dir=$(mise where java@temurin-17.0.16+8)
ndk_dir="$sdk_dir/ndk/28.2.13676358"
[ -f "$ndk_dir/source.properties" ] || { echo '缺少官方 NDK28.2.13676358；请先安装此固定版本。' >&2; exit 1; }
[ -f "$core_dir/mobilebridge/build-android.sh" ] || { echo '请先初始化 workspace 的 core-go 子模块。' >&2; exit 1; }
if [ ! -f "$core_dir/pairing/native/android-arm64/libcrypto.a" ]; then
 (cd "$core_dir/pairing" && mise run native-build-android "$ndk_dir")
fi
mise exec go@1.26.4 -- sh "$core_dir/mobilebridge/build-android.sh" "$sdk_dir" "$ndk_dir" "$java_dir"
# Gradle 可能记住未激活的 shim；只在 ignored 本机配置中固定真实 CMake 安装目录。
cmake_bin=$(mise exec cmake@3.31.8 -- which cmake)
cmake_dir=$(CDPATH= cd -- "$(dirname -- "$cmake_bin")/.." && pwd)
python3 - "$project_dir/android/local.properties" "$cmake_dir" "$sdk_dir" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines() if p.exists() else []
lines = [line for line in lines if not line.startswith(('cmake.dir=', 'sdk.dir='))]
lines.extend(['cmake.dir=' + sys.argv[2], 'sdk.dir=' + sys.argv[3]])
p.write_text('\n'.join(lines) + '\n')
PY
