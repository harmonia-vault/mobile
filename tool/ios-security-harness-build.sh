#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then echo '用法：ios-security-harness-build.sh <Flutter3.47.6目录> [独立合成fixture目录]' >&2; exit 2; fi
mobile_root=$(cd "$(dirname "$0")/.." && pwd)
flutter_root=$(cd "$1" && pwd)
output="$mobile_root/build/ios-security/HarmoniaSecurity.app"
mkdir -p "$output/Frameworks" "$mobile_root/build/ios-security/swift-cache"
framework="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cat > "$mobile_root/build/ios-security/SimulatorOnly.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>application-identifier</key><string>HARMONIATEST.org.harmoniavault.ios.security.synthetic.t20261003</string>
<key>keychain-access-groups</key><array><string>HARMONIATEST.org.harmoniavault.ios.security.synthetic.t20261003</string></array>
</dict></plist>
ENTITLEMENTS
# Simulator entitlement置于Mach-O模拟区段，不写为宿主macOS权限。
test_sources=()
for source in "$mobile_root"/ios/Runner/NativeBridge/*.swift; do
  if [[ "$(basename "$source")" != LocalPINSlot.swift ]]; then test_sources+=("$source"); fi
done
# 原生产文件字节保持不变；只有测试副本追加同文件private extension，不加入Runner。
cat "$mobile_root/ios/Runner/NativeBridge/LocalPINSlot.swift" "$mobile_root/ios/NativeSecurityTests/PINStorageComponentTests.swift" > "$mobile_root/build/ios-security/LocalPINSlotUnderTest.swift"
test_sources+=("$mobile_root/build/ios-security/LocalPINSlotUnderTest.swift")
xcrun swiftc -target arm64-apple-ios15.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -F "$mobile_root/build/native/Mobilebridge.xcframework/ios-arm64-simulator" -F "$framework" \
  -module-cache-path "$mobile_root/build/ios-security/swift-cache" \
  -framework UIKit -framework Foundation -framework Security -framework LocalAuthentication \
  -framework Mobilebridge -framework Flutter -lc++ -lresolv \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$mobile_root/build/ios-security/SimulatorOnly.entitlements" \
  "${test_sources[@]}" "$mobile_root/ios/NativeSecurityTests/SimulatorHarness.swift" \
  -o "$output/HarmoniaSecurity"
cp -R "$framework/Flutter.framework" "$output/Frameworks/"
cat > "$output/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.harmoniavault.ios.security.synthetic.t20261003</string>
<key>CFBundleExecutable</key><string>HarmoniaSecurity</string><key>CFBundleName</key><string>HarmoniaSecurity</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1</string>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict><key>UISceneConfigurationName</key><string>HarmoniaSecurity</string><key>UISceneDelegateClassName</key><string>HarmoniaHarnessSceneDelegate</string></dict></array></dict></dict>
<key>LSRequiresIPhoneOS</key><true/><key>MinimumOSVersion</key><string>15.0</string>
<key>NSFaceIDUsageDescription</key><string>仅合成安全测试验证本机系统认证边界。</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST
# 清除本脚本上轮自己的测试资源，禁止省略fixture却复用旧账号/CA。
rm -f "$output/HarmoniaSyntheticCA.pem" "$output/HarmoniaSyntheticAccount.json"
if [[ $# == 2 ]]; then
  cp "$2/ca.pem" "$output/HarmoniaSyntheticCA.pem"
  cp "$2/private-synthetic-account.json" "$output/HarmoniaSyntheticAccount.json"
fi
uuidgen > "$output/HarmoniaHarnessRunID.txt"
# 仅Simulator ad-hoc签名，无证书、账号、私钥或设备注册。
codesign --force --sign - "$output"
echo "$output"
