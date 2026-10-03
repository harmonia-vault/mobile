#!/usr/bin/env python3
"""固定工具链验证公共CA配置边界；不调用ADB、不模拟认证、不输出CA内容。"""
from pathlib import Path
import argparse, subprocess, tempfile, time

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-ca', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.source_root.resolve(strict=True)
    ca = args.public_ca.resolve(strict=True)
    if ca.stat().st_size not in range(1, 65537) or b'PRIVATE KEY' in ca.read_bytes():
        raise SystemExit('仅接受bounded公共证书。')
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    def jar(name, version):
        found = list((cache / name / version).glob('*/*.jar'))
        if len(found) != 1:
            raise RuntimeError('缺少固定编译缓存，未下载/更换版本。')
        return str(found[0])
    java = Path(subprocess.check_output(['mise', 'where', 'java@temurin-17.0.16+8'], cwd=root, text=True).strip()) / 'bin/java'
    dependencies = [('org.jetbrains.kotlin/kotlin-compiler-embeddable', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0'), ('org.jetbrains.kotlin/kotlin-script-runtime', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-reflect', '1.6.10'), ('org.jetbrains.kotlin/kotlin-daemon-embeddable', '2.4.0'),
        ('org.jetbrains.kotlin/kotlin-build-tools-api', '2.4.0'), ('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm', '1.8.0'),
        ('org.jetbrains/annotations', '13.0')]
    compiler = [jar(name, version) for name, version in dependencies]
    stdlib = jar('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0')
    main_source = root / 'android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/ProductFixtureConfiguration.kt'
    test_source = root / 'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/ProductFixtureConfigurationHostTest.kt'
    with tempfile.TemporaryDirectory(prefix='harmonia-productfixture-host-') as directory:
        output = Path(directory) / 'host.jar'
        start = time.monotonic()
        subprocess.run([str(java), '-cp', ':'.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
            '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', stdlib, '-d', str(output),
            str(main_source), str(test_source)], check=True)
        print('PASS fixed Kotlin2.4/Java17 config compile; seconds=' + str(round(time.monotonic() - start, 3)), flush=True)
        start = time.monotonic()
        subprocess.run([str(java), '-cp', str(output) + ':' + stdlib,
            'org.harmoniavault.harmonia_mobile.nativebridge.ProductFixtureConfigurationHostTest', str(ca)], check=True)
        print('PASS host run; seconds=' + str(round(time.monotonic() - start, 3)), flush=True)
        print('UNRUN Android/real TLS/product chain', flush=True)

if __name__ == '__main__':
    main()
