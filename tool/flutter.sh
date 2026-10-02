#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${HARMONIA_FLUTTER_SDK:-}" ]; then
  sdk_dir=$HARMONIA_FLUTTER_SDK
else
  sdk_dir=$(mise where flutter@3.47.6)
fi
flutter_bin="$sdk_dir/bin/flutter"
if [ ! -x "$flutter_bin" ]; then
  echo '未找到 Flutter；请安装官方 SDK 3.47.6，并设置 HARMONIA_FLUTTER_SDK。' >&2
  exit 1
fi
actual_version=$(FLUTTER_SUPPRESS_ANALYTICS=true CI=true "$flutter_bin" --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')
if [ "$actual_version" != '3.47.6' ]; then
  echo "需要 Flutter 3.47.6，当前为 $actual_version。" >&2
  exit 1
fi
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
exec "$flutter_bin" "$@"
