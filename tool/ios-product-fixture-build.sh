#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo '用法：ios-product-fixture-build.sh <Flutter3.47.6目录> <本次独立公共fixture JSON>' >&2; exit 2; fi
mobile=$(cd "$(dirname "$0")/.." && pwd)
flutter=$(cd "$1" && pwd)
fixture=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
output="$mobile/build/ios-product-fixture"
mkdir -p "$output"
# 只接收本任务公共CA配置，不读取账号、私钥或env。先标准工具验证，再打包到独立debug App。
python3 - "$fixture" "$output" <<'PY'
import pathlib,sys,json,re,subprocess,tempfile,plistlib
source=pathlib.Path(sys.argv[1]);output=pathlib.Path(sys.argv[2])
if source.stat().st_size>70000:raise SystemExit('公共配置超限')
def unique(pairs):
 result={}
 for k,v in pairs:
  if k in result:raise ValueError('重复字段')
  result[k]=v
 return result
v=json.loads(source.read_bytes(),object_pairs_hook=unique)
if set(v)!={'endpoint','caPem'} or v['endpoint'] not in ('https://10.0.2.2:5593','https://127.0.0.1:5593'):raise SystemExit('仅允许本次5593独立fixture')
pem=v['caPem']
if not isinstance(pem,str) or len(pem.encode())>65536 or not re.fullmatch(r'-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\r?\n?',pem):raise SystemExit('只接受单个公共CA')
with tempfile.TemporaryDirectory(prefix='harmonia-ios-public-ca-') as temporary:
 certificate=pathlib.Path(temporary)/'ca.pem';certificate.write_text(pem,encoding='ascii')
 subprocess.run(['/usr/bin/openssl','verify','-CAfile',str(certificate),'-check_ss_sig',str(certificate)],check=True,stdout=subprocess.DEVNULL)
 description=subprocess.check_output(['/usr/bin/openssl','x509','-in',str(certificate),'-text','-noout'],text=True)
 if 'CA:TRUE' not in description or 'Certificate Sign' not in description:raise SystemExit('证书必须有CA/签发用途')
bundle='org.harmoniavault.ios.productfixture'
(output/'SimulatorOnly.entitlements').write_bytes(plistlib.dumps({'application-identifier':'HARMONIATEST.'+bundle,'keychain-access-groups':['HARMONIATEST.'+bundle]}))
v['endpoint']='https://127.0.0.1:5593'
(output/'HarmoniaProductFixture.json').write_text(json.dumps(v,separators=(',',':'))+'\n')
PY
cd "$mobile"
"$flutter/bin/flutter" pub get --offline
"$flutter/bin/flutter" build ios --debug --simulator --config-only --no-codesign \
 --dart-define=HARMONIA_NATIVE_EXPERIMENTAL=true --dart-define=HARMONIA_PRODUCT_FIXTURE=true
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator \
 -destination 'generic/platform=iOS Simulator' -derivedDataPath "$output/DerivedData" \
 PRODUCT_BUNDLE_IDENTIFIER=org.harmoniavault.ios.productfixture \
 SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG HARMONIA_PRODUCT_FIXTURE' \
 ENABLE_DEBUG_DYLIB=NO \
 "OTHER_LDFLAGS=\$(inherited) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker \"$output/SimulatorOnly.entitlements\"" \
 CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
app="$output/DerivedData/Build/Products/Debug-iphonesimulator/Runner.app"
cp "$output/HarmoniaProductFixture.json" "$app/HarmoniaProductFixture.json"
# 仅本地Simulator ad-hoc，无Developer账号、签名私钥或发布。
codesign --force --sign - "$app"
printf '%s\n' "$app"
