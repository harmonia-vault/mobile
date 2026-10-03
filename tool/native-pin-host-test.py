#!/usr/bin/env python3
"""独立PIN适配编译/主机合同验证；不调用Gradle/ADB/Go AAR，不冒称Android实测。"""
from pathlib import Path
import argparse
import subprocess
import tempfile
import time
import zipfile


def run() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    project = args.source_root.resolve()
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"

    def jar(name: str, version: str) -> str:
        matches = list((cache / name / version).glob("*/*.jar"))
        if len(matches) != 1:
            raise RuntimeError("缺少固定本地编译依赖；未自动下载或替换版本: " + name + "@" + version)
        return str(matches[0])

    def mise_where(name: str) -> Path:
        return Path(subprocess.check_output(["mise", "where", name], cwd=project, text=True).strip())

    java = mise_where("java@temurin-17.0.16+8") / "bin/java"
    android = mise_where("android-sdk@19.0") / "platforms/android-36/android.jar"
    if not android.is_file():
        raise RuntimeError("缺少固定Android API36；未安装或切换SDK")
    compiler = [
        jar("org.jetbrains.kotlin/kotlin-compiler-embeddable", "2.4.0"),
        jar("org.jetbrains.kotlin/kotlin-stdlib", "2.4.0"),
        jar("org.jetbrains.kotlin/kotlin-script-runtime", "2.4.0"),
        jar("org.jetbrains.kotlin/kotlin-reflect", "1.6.10"),
        jar("org.jetbrains.kotlin/kotlin-daemon-embeddable", "2.4.0"),
        jar("org.jetbrains.kotlin/kotlin-build-tools-api", "2.4.0"),
        jar("org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm", "1.8.0"),
        jar("org.jetbrains/annotations", "13.0"),
    ]
    main = project / "android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/pinlocal"
    test = project / "android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/pinlocal/PinLocalAdapterHostTest.kt"
    instrumentation = project / "android/app/src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/pinlocal/PinLocalStoreAndroidTest.kt"
    sources = [main / name for name in ("PinCapabilityClassifier.kt", "PinKeystoreStore.kt", "LocalPinProvider.kt")]
    sources.extend([test, instrumentation])
    if any(not source.is_file() for source in sources):
        raise RuntimeError("缺少独立PIN候选源码")
    monitor = list((cache / "androidx.test/monitor/1.8.0").glob("*/*.aar"))
    if len(monitor) != 1:
        raise RuntimeError("缺少固定Android test monitor1.8.0；未自动下载")
    with tempfile.TemporaryDirectory(prefix="harmonia-pin-host-") as temporary:
        work = Path(temporary)
        monitor_jar = work / "monitor.jar"
        with zipfile.ZipFile(monitor[0]) as archive:
            monitor_jar.write_bytes(archive.read("classes.jar"))
        stdlib = jar("org.jetbrains.kotlin/kotlin-stdlib", "2.4.0")
        application_cp = [stdlib, str(android), jar("junit/junit", "4.13.2"), jar("org.hamcrest/hamcrest-core", "1.3"), str(monitor_jar)]
        output = work / "pin-host.jar"
        start = time.monotonic()
        subprocess.run([str(java), "-cp", ":".join(compiler), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", ":".join(application_cp), "-d", str(output), *map(str, sources)], check=True)
        print("PASS fixed Kotlin2.4/API36 compile (3 native classes + 2 test sources); seconds=" + str(round(time.monotonic() - start, 3)), flush=True)
        # 只调用主机main，不执行Android stub的Keystore/AtomicFile/provider。
        start = time.monotonic()
        subprocess.run([str(java), "-cp", ":".join([str(output), stdlib, str(android)]), "org.harmoniavault.harmonia_mobile.nativebridge.pinlocal.PinLocalAdapterHostTest"], check=True)
        print("PASS host run; seconds=" + str(round(time.monotonic() - start, 3)), flush=True)
        print("UNRUN Android instrumentation / system classifier / Keystore / AtomicFile / PIN Go wrapper / product", flush=True)


if __name__ == "__main__":
    run()
