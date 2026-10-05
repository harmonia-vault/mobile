#!/usr/bin/env python3
"""只编译androidTest产品驱动API；不构建/安装APK，不调用ADB或任何服务。"""
from pathlib import Path
import argparse
import json
import subprocess
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.source_root.resolve(strict=True)
    output = args.output.absolute()
    if output.exists():
        raise SystemExit('编译输出必须是新的隔离目录。')
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    def jar(name, version):
        found = list((cache / name / version).glob('*/*.jar'))
        if len(found) != 1:
            raise RuntimeError('缺少固定本地编译缓存，未自动下载。')
        return str(found[0])
    def installed(name):
        return Path(subprocess.check_output(['mise', 'where', name], cwd=root, text=True).strip())
    java_root = installed('java@temurin-17.0.16+8')
    android = installed('android-sdk@19.0') / 'platforms/android-36/android.jar'
    compiler = [jar(name, version) for name, version in [
        ('org.jetbrains.kotlin/kotlin-compiler-embeddable', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0'), ('org.jetbrains.kotlin/kotlin-script-runtime', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-reflect', '1.6.10'), ('org.jetbrains.kotlin/kotlin-daemon-embeddable', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-build-tools-api', '2.4.0'), ('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm', '1.8.0'),
        ('org.jetbrains/annotations', '13.0')]]
    monitor = list((cache / 'androidx.test/monitor/1.8.0').glob('*/*.aar'))
    if len(monitor) != 1 or not android.is_file():
        raise RuntimeError('缺少固定API36/test-monitor1.8缓存。')
    source = root / 'android/app/src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/productqa/NativeProductUiDriverTest.kt'
    command_source = source.parent / 'ProductQaCommand.kt'
    command_test = root / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/productqa/ProductQaCommandHostTest.kt'
    if any(not path.is_file() for path in (source, command_source, command_test)):
        raise RuntimeError('缺少独立androidTest驱动。')
    output.mkdir(parents=True, mode=0o700)
    monitor_jar = output / 'monitor.jar'
    with zipfile.ZipFile(monitor[0]) as archive:
        monitor_jar.write_bytes(archive.read('classes.jar'))
    # 只提供编译API符号；false常量使该临时编译产物无法通过目标包门槛。
    # 后续真实test APK必须由已审Gradle productfixture生成实际BuildConfig，绝不复用此jar。
    symbols = output / 'BuildConfig.java'
    symbols.write_text('package org.harmoniavault.harmonia_mobile; public final class BuildConfig { public static final boolean DEBUG=false; public static final boolean HARMONIA_PRODUCT_FIXTURE=false; }\n')
    classes = output / 'symbols'
    classes.mkdir()
    subprocess.run([str(java_root / 'bin/javac'), '-d', str(classes), str(symbols)], check=True)
    stdlib = jar('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0')
    cp = [stdlib, str(android), jar('junit/junit', '4.13.2'), str(monitor_jar), str(classes)]
    start = time.monotonic()
    subprocess.run([str(java_root / 'bin/java'), '-cp', ':'.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
        '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', ':'.join(cp), '-d', str(output / 'driver-api-only.jar'), str(source), str(command_source), str(command_test)], check=True)
    result = {'status':'PASS', 'seconds':round(time.monotonic()-start,3),
        'scope':'Kotlin2.4/Java17/API36 source compatibility only',
        'runtime':'UNRUN APK/AVD/Flutter/accessibility/system-auth/TLS/CLI', 'apiSymbolFixtureFlags':False}
    print('PASS product QA driver API compile; seconds='+str(result['seconds']), flush=True)
    subprocess.run([str(java_root / 'bin/java'), '-cp', str(output / 'driver-api-only.jar') + ':' + stdlib,
        'org.harmoniavault.harmonia_mobile.productqa.ProductQaCommandHostTest'], check=True)
    result['hostFlatCommandBoundary'] = 'PASS positive + 11 fixed rejects; non-UI/non-Android'
    (output / 'compile-result.json').write_text(json.dumps(result,indent=2)+'\n')
    print('UNRUN all Android runtime; API-only jar must never be installed or reused by actual APK', flush=True)

if __name__ == '__main__':
    main()
