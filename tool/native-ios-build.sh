#!/bin/bash
set -euo pipefail
# 仅固定源码、隔离构建缓存与 ignored 产物；不运行 gomobile init（其内部会安装 @latest）。
if [[ $# != 3 ]]; then
  echo '用法：native-ios-build.sh <core-go目录> <固定BoringSSL源码> <固定gomobile工具目录>' >&2
  exit 2
fi
mobile_root=$(cd "$(dirname "$0")/.." && pwd)
core_root=$(cd "$1" && pwd)
boring_source=$(cd "$2" && pwd)
mobile_tools=$(cd "$3" && pwd)
[[ "$(go version | awk '{print $3}')" == go1.26.4 ]]
[[ "$(git -C "$boring_source" rev-parse HEAD)" == fab96f87245d7c6b941515201843665122650b88 ]]
[[ -z "$(git -C "$boring_source" status --porcelain --untracked-files=no)" ]]
for tool in gomobile gobind; do
  go version -m "$mobile_tools/$tool" | rg -q 'golang.org/x/mobile[[:space:]]+v0.0.0-20260908204917-8b95e45f8d3e[[:space:]]'
done
cache="$mobile_root/build/ios-native"
if [[ -e "$mobile_root/build/native/Mobilebridge.xcframework" ]]; then
  echo "输出已存在，请使用新的隔离构建目录。" >&2; exit 2
fi
mkdir -p "$cache/gopath/pkg/gomobile" "$cache/go-cache" "$mobile_root/build/native" "$core_root/pairing/native/include"
export GOPATH="$cache/gopath" GOCACHE="$cache/go-cache" CLANG_MODULE_CACHE_PATH="$cache/clang-modules"
export PATH="$mobile_tools:$PATH"
cp -R "$boring_source/include/openssl" "$core_root/pairing/native/include/"
cp "$boring_source/LICENSE" "$core_root/pairing/native/LICENSE"
for target in ios-simulator-arm64 ios-arm64; do
  sdk=iphonesimulator
  bind_target=iossimulator/arm64
  tags=harmonia_boringssl,harmonia_ios_simulator
  if [[ "$target" == ios-arm64 ]]; then sdk=iphoneos; bind_target=ios/arm64; tags=harmonia_boringssl; fi
  cmake -S "$boring_source" -B "$cache/$target" -GNinja -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBORINGSSL_PREFIX=HARMONIA_BSSL
  cmake --build "$cache/$target" --target crypto --parallel 4
  mkdir -p "$core_root/pairing/native/$target" "$cache/$target-bind"
  cp "$cache/$target/libcrypto.a" "$core_root/pairing/native/$target/libcrypto.a"
  (cd "$core_root/mobilebridge/binding" && gomobile bind -target "$bind_target" \
    -iosversion 15.0 -tags "$tags" -trimpath -o "$cache/$target-bind/Mobilebridge.xcframework" \
    github.com/harmonia-vault/core-go/mobilebridge)
  slice=ios-arm64-simulator
  if [[ "$target" == ios-arm64 ]]; then slice=ios-arm64; fi
  binary="$cache/$target-bind/Mobilebridge.xcframework/$slice/Mobilebridge.framework/Mobilebridge"
  # Go c-archive 不包含传给 cgo 的外部静态依赖；实际合并固定 BoringSSL 后再封装。
  xcrun libtool -static -o "$cache/$target-combined.a" "$binary" "$core_root/pairing/native/$target/libcrypto.a"
  cp "$cache/$target-combined.a" "$binary"
done
xcodebuild -create-xcframework \
  -framework "$cache/ios-simulator-arm64-bind/Mobilebridge.xcframework/ios-arm64-simulator/Mobilebridge.framework" \
  -framework "$cache/ios-arm64-bind/Mobilebridge.xcframework/ios-arm64/Mobilebridge.framework" \
  -output "$mobile_root/build/native/Mobilebridge.xcframework"
