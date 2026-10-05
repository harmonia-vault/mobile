"""仅在本次创建的独立 Simulator 中运行合成原生检查。"""
import json
import pathlib
import subprocess
import uuid

root = pathlib.Path(__file__).resolve().parent.parent


def simctl(*args, timeout=30):
    return subprocess.check_output(
        ["xcrun", "simctl", *args], text=True, timeout=timeout
    ).strip()


runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
runtime = next(r for r in reversed(runtimes) if r["isAvailable"] and "iOS" in r["name"])
name = "Harmonia-iOS-Synthetic-access-" + uuid.uuid4().hex[:10]
device = simctl("create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime["identifier"])
try:
    print("独立原生检查设备：" + device, flush=True)
    simctl("boot", device)
    simctl("bootstatus", device, "-b", timeout=240)
    subprocess.run(
        ["python3", str(root / "tool/ios-security-test.py"), "--device", device],
        check=True, timeout=120,
    )
finally:
    subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=30)
    simctl("delete", device)
