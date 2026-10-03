"""固定 B dispatcher/Kotlin/API36 编译与纯 lifecycle/cleanup host 证据；不启动 Android 或 JNI。"""
from pathlib import Path
import argparse, hashlib, json, subprocess, time, zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--aar', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.candidate.resolve(strict=True)
mobile = root / 'mobile'
out = args.output.resolve()
out.mkdir(exist_ok=False)
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def jar(name, version):
    paths = list((cache / name / version).glob('*/*.jar'))
    if len(paths) != 1:
        raise RuntimeError('fixed compiler dependency unavailable')
    return paths[0]

def where(name):
    return Path(subprocess.check_output(['mise', 'where', name], cwd=mobile, text=True).strip())

java = where('java@temurin-17.0.16+8') / 'bin/java'
sdk = where('android-sdk@19.0') / 'platforms/android-36/android.jar'
compiler = [jar(name, version) for name, version in [
    ('org.jetbrains.kotlin/kotlin-compiler-embeddable', '2.4.0'),
    ('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0'),
    ('org.jetbrains.kotlin/kotlin-script-runtime', '2.4.0'),
    ('org.jetbrains.kotlin/kotlin-reflect', '1.6.10'),
    ('org.jetbrains.kotlin/kotlin-daemon-embeddable', '2.4.0'),
    ('org.jetbrains.kotlin/kotlin-build-tools-api', '2.4.0'),
    ('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm', '1.8.0'),
    ('org.jetbrains/annotations', '13.0'),
]]
stdlib = jar('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0')
embedding = jar('io.flutter/flutter_embedding_debug', '1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0')
with zipfile.ZipFile(args.aar.resolve(strict=True)) as archive:
    (out / 'go.jar').write_bytes(archive.read('classes.jar'))
# 仅复现 Gradle 生成类型的编译 stub；不是 App 运行或 flavor 实证。
build_config = out / 'BuildConfig.kt'
build_config.write_text('''package org.harmoniavault.harmonia_mobile
internal object BuildConfig {
 const val DEBUG = true
 const val HARMONIA_PRODUCT_FIXTURE = false
 const val HARMONIA_FIXTURE_ENDPOINT = ""
 const val HARMONIA_FIXTURE_CA_BASE64 = ""
}
''')
base = mobile / 'android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile'
sources = sorted((base / 'nativebridge').rglob('*.kt')) + [
    base / 'MainActivity.kt',
    mobile / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeSlotLifecycleHostTest.kt',
    mobile / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeDAGABISignatureProbe.kt',
    mobile / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeDAGCleanupHostTest.kt',
    mobile / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeDAGCompletedDeadlineReview.kt',
    build_config,
]
# 官方固定 embedding POM 声明 lifecycle-common2.7.0，编译真实 FlutterActivity 父接口。
lifecycle = jar('androidx.lifecycle/lifecycle-common', '2.7.0')
cp = [stdlib, sdk, out / 'go.jar', embedding, lifecycle]
command = [str(java), '-cp', ':'.join(map(str, compiler)),
    'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
    '-jvm-target', '17', '-classpath', ':'.join(map(str, cp)), '-d', str(out / 'candidate.jar'), *map(str, sources)]
started = time.monotonic()
compiled = subprocess.run(command, capture_output=True)
(out / 'compile.log').write_bytes(compiled.stdout + compiled.stderr)
result = {
    'compileExit': compiled.returncode, 'compileSeconds': round(time.monotonic() - started, 3),
    'sources': {str(path.relative_to(mobile)) if path.is_relative_to(mobile) else 'generated/' + path.name: sha(path) for path in sources},
    'compilerInputs': {str(path): sha(path) for path in compiler + cp},
    'aarSHA256': sha(args.aar.resolve(strict=True)), 'command': command,
    'androidRuntime': 'UNRUN', 'JNIExecution': 'UNRUN', 'deviceCredential': 'UNRUN', 'appBuild': 'UNRUN',
}
if compiled.returncode == 0:
    host_results = []
    host_log = bytearray()
    for entry in ['NativeSlotLifecycleHostTest', 'NativeDAGCleanupHostTest', 'NativeDAGCompletedDeadlineReview']:
        started = time.monotonic()
        host = subprocess.run([str(java), '-cp', str(out / 'candidate.jar') + ':' + str(stdlib),
            'org.harmoniavault.harmonia_mobile.nativebridge.' + entry], capture_output=True)
        host_log.extend(host.stdout + host.stderr)
        host_results.append({'entry': entry, 'exitCode': host.returncode, 'seconds': round(time.monotonic() - started, 3)})
        print(host.stdout.decode(), end='')
    (out / 'host.log').write_bytes(host_log)
    result.update(hostExit=next((row['exitCode'] for row in host_results if row['exitCode'] != 0), 0),
        hostSeconds=round(sum(row['seconds'] for row in host_results), 3), hostCases=host_results)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print('compileExit=' + str(compiled.returncode))
if compiled.returncode:
    print(compiled.stderr.decode())
raise SystemExit(compiled.returncode or result.get('hostExit', 0))
