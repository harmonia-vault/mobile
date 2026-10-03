#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo '用法：ios-product-fixture-gate-test.sh <独立Simulator UUID> <经build脚本验证的公共fixture JSON>' >&2; exit 2; fi
mobile=$(cd "$(dirname "$0")/.." && pwd)
simulator=$1
fixture=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
output="$mobile/build/ios-product-fixture-gates"
mkdir -p "$output"
mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
SDKROOT="$mac_sdk" xcrun --sdk macosx swiftc -sdk "$mac_sdk" \
 "$mobile/ios/Runner/NativeBridge/SystemAuthentication.swift" \
 "$mobile/ios/Runner/NativeBridge/ProductFixtureConfiguration.swift" \
 "$mobile/ios/NativeSecurityTests/ProductFixtureConfigurationTests.swift" \
 -o "$output/fixture-configuration-tests"
"$output/fixture-configuration-tests" "$fixture"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
export SDKROOT="$sdk"
for case_name in ordinary-empty ordinary-resource debug-wrong-bundle; do
 app="$output/$case_name.app"
 mkdir -p "$app"
 bundle="org.harmoniavault.ios.fixturegates.$case_name"
 expected=rejected
 flags=(-DHARMONIA_FIXTURE_GATE_TEST)
 if [[ "$case_name" == ordinary-empty ]]; then expected=disabled; fi
 if [[ "$case_name" == debug-wrong-bundle ]]; then flags=(-DDEBUG -DHARMONIA_PRODUCT_FIXTURE); fi
 run_id=$(uuidgen)
 python3 - "$app" "$bundle" "$expected" "$run_id" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);info={'CFBundleIdentifier':sys.argv[2],'CFBundleExecutable':'FixtureGateHarness','CFBundleName':'FixtureGateHarness','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'15.0','UIDeviceFamily':[1,2],'UILaunchScreen':{},'FixtureGateExpected':sys.argv[3],'FixtureGateRunID':sys.argv[4],'LSRequiresIPhoneOS':True,'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'FixtureGate','UISceneDelegateClassName':'ProductFixtureGateScene'}]}}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
 # 普通无资源包与另外两包使用不同路径，不删除或覆盖产品包。
 if [[ "$case_name" != ordinary-empty ]]; then cp "$fixture" "$app/HarmoniaProductFixture.json"; fi
 xcrun swiftc -sdk "$sdk" -target arm64-apple-ios15.0-simulator "${flags[@]}" \
  "$mobile/ios/Runner/NativeBridge/SystemAuthentication.swift" \
  "$mobile/ios/Runner/NativeBridge/ProductFixtureConfiguration.swift" \
  "$mobile/ios/NativeSecurityTests/ProductFixtureGateHarness.swift" \
  -o "$app/FixtureGateHarness"
 codesign --force --sign - "$app"
 xcrun simctl install "$simulator" "$app"
 xcrun simctl launch "$simulator" "$bundle"
 container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
 python3 - "$container/Documents/fixture-gate-result.json" "$output/$case_name.json" "$run_id" <<'PY'
import pathlib,sys,json,time
source=pathlib.Path(sys.argv[1]);target=pathlib.Path(sys.argv[2])
v=None
for _ in range(50):
 if source.exists():
  candidate=json.loads(source.read_bytes())
  if candidate.get('runID')==sys.argv[3]:v=candidate;break
 time.sleep(.2)
if v is None:raise SystemExit('本次配置门槛没有产生结果')
target.write_text(json.dumps(v,sort_keys=True)+'\n')
if v['result']!='PASS' or v['authenticationInvoked'] is not False:raise SystemExit('实际配置门槛失败')
print(json.dumps(v,sort_keys=True))
PY
 xcrun simctl terminate "$simulator" "$bundle"
done
