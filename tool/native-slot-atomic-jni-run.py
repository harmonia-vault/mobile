#!/usr/bin/env python3
"""仅固定两项JNI验收；无系统凭证设置，实际运行仍需root已审manifest。"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,time

METHODS = ["realGoProxyCheckAndCASThenOrdinarySave", "typedOpenerRetainsRealJNIAtomicInterface"]
TEST_CLASS = "org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotOwnerAndroidTest"
PACKAGES = ["org.harmoniavault.slotownerfixture", "org.harmoniavault.slotownerfixture.test"]
REFERENCE = "https://developer.android.com/reference/androidx/test/runner/AndroidJUnitRunner"

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
class FixedFailure(Exception): pass
def require(ok, code):
    if not ok: raise FixedFailure(code)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--candidate",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    p.add_argument("--serial",required=True);p.add_argument("--reviewed-manifest",required=True)
    p.add_argument("--expected-emulator-pid",type=int,required=True);a=p.parse_args()
    A=a.candidate.resolve(strict=True);out=a.output.resolve(strict=True)
    require(not any((out/name).exists() or (out/name).is_symlink() for name in ["jni-runtime-result.json", *(method+".log" for method in METHODS)]),"EVIDENCE_OUTPUT_EXISTS")
    require(a.serial=="emulator-5580" and sha(out/"run-manifest.json")==a.reviewed_manifest,"REVIEW_GUARD_REJECTED")
    manifest=json.loads((out/"run-manifest.json").read_text())
    require(manifest["status"]=="PASS" and manifest["selectedMethods"]==METHODS and manifest["systemCredentialSetup"] is False,"SELECTION_REJECTED")
    require(sha(out/"manifest.json")==manifest["compiledBuildManifestSHA256"],"BUILD_MANIFEST_CHANGED")
    for name,h in manifest["apk"].items(): require(sha(out/name)==h,"APK_CHANGED")
    for name,h in manifest["inputs"].items(): require(sha(A/name)==h,"SOURCE_CHANGED")
    require(manifest["inputs"].get(str(Path(__file__).resolve().relative_to(A)))==sha(Path(__file__).resolve()),"RUNNER_CHANGED")
    sdk=Path(subprocess.check_output(["mise","where","android-sdk@19.0"],cwd=A/"mobile",text=True).strip());adb=sdk/"platform-tools/adb"
    def call(args,timeout=20):
        try: return subprocess.run([str(adb),"-s",a.serial,*args],capture_output=True,text=True,timeout=timeout)
        except Exception: raise FixedFailure("SDK_COMMAND_FAILED") from None
    def packages():
        r=call(["shell","pm","list","packages"]);require(r.returncode==0,"PACKAGE_LIST_UNKNOWN");return set(r.stdout.splitlines())
    def secure():
        r=call(["shell","am","instrument","-w","-r","-e","class","org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotSecurityProbeTest",PACKAGES[1]+"/androidx.test.runner.AndroidJUnitRunner"])
        values=re.findall(r"^INSTRUMENTATION_STATUS: SDK_DEVICE_SECURE=(true|false)$",r.stdout,re.M)
        require(r.returncode==0 and "OK (1 test)" in r.stdout and len(values)==1,"SDK_SECURITY_STATE_UNKNOWN");return values[0]=="true"
    identity=subprocess.run(["ps","-p",str(a.expected_emulator_pid),"-o","pid=,command="],capture_output=True,text=True)
    require(identity.returncode==0 and len(identity.stdout.splitlines())==1 and "qemu-system-aarch64" in identity.stdout and "-avd harmonia-test-api34" in identity.stdout and "-port 5580" in identity.stdout,"VM_IDENTITY_REJECTED");identity=None
    require(call(["shell","getprop","ro.kernel.qemu"]).stdout.strip()=="1" and call(["shell","getprop","ro.build.version.sdk"]).stdout.strip()=="34","VM_PROFILE_REJECTED")
    baseline=packages();require(all("package:"+s not in baseline for s in PACKAGES),"TARGET_PACKAGE_EXISTS")
    result={"runtime":"UNRUN","selectedMethods":METHODS,"systemCredentialSetup":False,"credentialInputs":0,"credentialCancellations":0,"cases":{},"packagesCleaned":False}
    def save(): (out/"jni-runtime-result.json").write_text(json.dumps(result,indent=2)+"\n")
    installed=0;start=time.monotonic()
    try:
        for name in sorted(manifest["apk"],key=lambda s:"androidTest" in s):
            r=call(["install",str(out/name)],60);require(r.returncode==0 and "Success" in r.stdout,"INSTALL_FAILED");installed+=1
        require(not secure(),"BASELINE_HAS_SYSTEM_CREDENTIAL");result["SDKBaselineNoSecure"]=True
        result["runtime"]="RUNNING";save()
        for method in METHODS:
            # 官方JUnitRunner单方法选择；不运行其余四个已通过场景。
            r=call(["shell","am","instrument","-w","-r","-e","class",TEST_CLASS+"#"+method,PACKAGES[1]+"/androidx.test.runner.AndroidJUnitRunner"],45)
            (out/(method+".log")).write_text(r.stdout+r.stderr)
            observed=set(re.findall(r"^INSTRUMENTATION_STATUS: test=(\w+)$",r.stdout,re.M))
            ok=r.returncode==0 and "OK (1 test)" in r.stdout and observed=={method}
            result["cases"][method]="PASS" if ok else "FAIL";save()
        result.update(runtime="PASS" if all(v=="PASS" for v in result["cases"].values()) else "FAIL",seconds=round(time.monotonic()-start,3))
    except FixedFailure as failure: result.update(runtime="FAIL",error=str(failure))
    except Exception: result.update(runtime="FAIL",error="HOST_REJECTED")
    finally:
        if installed==2:
            try: result["SDKFinallyNoSecure"]=not secure()
            except Exception: result["SDKFinallyNoSecure"]=False
        for pkg in reversed(PACKAGES):
            try:
                if "package:"+pkg in packages():
                    require(call(["shell","am","force-stop",pkg]).returncode==0,"WORKER_DRAIN_UNKNOWN")
                    r=call(["uninstall",pkg]);require(r.returncode==0 and "Success" in r.stdout,"PACKAGE_CLEANUP_FAILED")
            except Exception: result["cleanupBlocker"]="OWN_PACKAGE_CLEANUP_UNKNOWN"
        try:
            remaining=packages();result["packagesCleaned"]=all("package:"+s not in remaining for s in PACKAGES)
            result["baselinePackageSetPreserved"]=remaining==baseline
        except Exception: result["cleanupBlocker"]="PACKAGE_SET_UNKNOWN"
        if "cleanupBlocker" in result: result["runtime"]="FAIL"
        save();print(json.dumps(result))
    raise SystemExit(0 if result["runtime"]=="PASS" and result["packagesCleaned"] and result.get("baselinePackageSetPreserved") and result.get("SDKFinallyNoSecure") and "cleanupBlocker" not in result else 1)
if __name__=="__main__": main()
