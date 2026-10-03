#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then echo '用法：ios-official-auth-build.sh <Flutter3.47.6目录>' >&2; exit 2; fi
mobile=$(cd "$(dirname "$0")/.." && pwd)
root="$mobile/build/ios-official-auth"
flutter_root=$(cd "$1" && pwd)
flutter="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
app="$root/HarmoniaOfficialAuth.app"
mkdir -p "$app/Frameworks" "$root/swift-cache"
python3 - "$root" <<'PY'
import pathlib,sys,plistlib,uuid
root=pathlib.Path(sys.argv[1]);bundle='org.harmoniavault.ios.auth.synthetic.t20261003'
p={'CFBundleIdentifier':bundle,'CFBundleExecutable':'HarmoniaOfficialAuth','CFBundleName':'HarmoniaOfficialAuth',
'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','LSRequiresIPhoneOS':True,
'MinimumOSVersion':'15.0','UIDeviceFamily':[1,2],'NSFaceIDUsageDescription':'仅合成测试验证系统认证与钥匙读取。',
'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'HarmoniaOfficialAuth','UISceneDelegateClassName':'HarmoniaOfficialAuthScene'}]}}}
(root/'HarmoniaOfficialAuth.app/Info.plist').write_bytes(plistlib.dumps(p))
(root/'SimulatorOnly.entitlements').write_bytes(plistlib.dumps({'application-identifier':'HARMONIATEST.'+bundle,'keychain-access-groups':['HARMONIATEST.'+bundle]}))
(root/'run-id.txt').write_text(str(uuid.uuid4())+'\n')
PY
export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -target arm64-apple-ios15.0-simulator -sdk "$SDKROOT" \
 -F "$mobile/build/native/Mobilebridge.xcframework/ios-arm64-simulator" -F "$flutter" \
 -module-cache-path "$root/swift-cache" -framework UIKit -framework Foundation -framework Security -framework LocalAuthentication -framework Mobilebridge -framework Flutter -lc++ -lresolv \
 -Xlinker -rpath -Xlinker @executable_path/Frameworks \
 -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$root/SimulatorOnly.entitlements" \
 "$mobile"/ios/Runner/NativeBridge/*.swift "$mobile/ios/NativeSecurityTests/OfficialAuthHarness.swift" -o "$app/HarmoniaOfficialAuth"
cp -R "$flutter/Flutter.framework" "$app/Frameworks/"
cp "$root/run-id.txt" "$app/HarmoniaHarnessRunID.txt"
codesign --force --sign - "$app"
