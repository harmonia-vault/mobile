#!/usr/bin/env python3
"""固定 Kotlin/API36 合同测试；显式接 gobind Java ABI jar，不构建/替换产品 AAR。"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import time


def run() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--abi-jar", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    project = args.source_root.resolve()
    abi = args.abi_jar.resolve(strict=True)
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"

    def jar(name: str, version: str) -> str:
        matches = list((cache / name / version).glob("*/*.jar"))
        if len(matches) != 1:
            raise RuntimeError("缺少固定已缓存依赖，未下载或替换版本: " + name + "@" + version)
        return str(matches[0])

    def where(name: str) -> Path:
        return Path(subprocess.check_output(["mise", "where", name], cwd=project, text=True).strip())

    java = where("java@temurin-17.0.16+8") / "bin/java"
    android = where("android-sdk@19.0") / "platforms/android-36/android.jar"
    compiler = [jar(name, version) for name, version in [
        ("org.jetbrains.kotlin/kotlin-compiler-embeddable", "2.4.0"),
        ("org.jetbrains.kotlin/kotlin-stdlib", "2.4.0"),
        ("org.jetbrains.kotlin/kotlin-script-runtime", "2.4.0"),
        ("org.jetbrains.kotlin/kotlin-reflect", "1.6.10"),
        ("org.jetbrains.kotlin/kotlin-daemon-embeddable", "2.4.0"),
        ("org.jetbrains.kotlin/kotlin-build-tools-api", "2.4.0"),
        ("org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm", "1.8.0"),
        ("org.jetbrains/annotations", "13.0"),
    ]]
    stdlib = jar("org.jetbrains.kotlin/kotlin-stdlib", "2.4.0")
    main = project / "android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/pinlocal"
    sources = [main / name for name in ["PinCapabilityClassifier.kt", "PinKeystoreStore.kt", "LocalPinProvider.kt", "PinNativeSlot.kt", "NativePinCoreAdapter.kt"]]
    sources += [project / "android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/pinlocal/NativePinCoreAdapterHostTest.kt"]
    results = []
    with tempfile.TemporaryDirectory(prefix="harmonia-pin-core-host-") as temporary:
        output = Path(temporary) / "pin-native-core-host.jar"
        commands = [
            ("compile", [str(java), "-cp", ":".join(compiler), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", ":".join([stdlib, str(android), str(abi)]), "-d", str(output), *map(str, sources)]),
            ("host", [str(java), "-cp", ":".join([str(output), stdlib, str(android), str(abi)]), "org.harmoniavault.harmonia_mobile.nativebridge.pinlocal.NativePinCoreAdapterHostTest"]),
        ]
        for name, command in commands:
            start = time.monotonic()
            result = subprocess.run(command, capture_output=True, text=True)
            (evidence / (name + ".txt")).write_text(result.stdout + result.stderr)
            elapsed = round(time.monotonic() - start, 3)
            results.append({"name": name, "exitCode": result.returncode, "wallSeconds": elapsed})
            (evidence / "RESULTS.json").write_text(json.dumps(results, indent=2) + "\n")
            print(result.stdout + result.stderr, end="")
            print(name + " exit=" + str(result.returncode) + " seconds=" + str(elapsed), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
    print("UNRUN Android JNI/classifier/Keystore+Go/AtomicFile/product; no AAR/Plugin/cap changes")


if __name__ == "__main__":
    run()
