#!/usr/bin/env python3
"""独立debug store/JNI验收；build无ADB，run须父任务review固定manifest后显式调用。"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,time,zipfile,queue,threading,secrets,re

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['build','run']);p.add_argument('--candidate',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--serial');p.add_argument('--reviewed-manifest');p.add_argument('--expected-emulator-pid',type=int);a=p.parse_args()
    A=a.candidate.resolve(strict=True);out=a.output.resolve();mobile=A/'mobile'
    def tool(name):return Path(subprocess.check_output(['mise','where',name],cwd=mobile,text=True).strip())
    java=tool('java@temurin-17.0.16+8');sdk=tool('android-sdk@19.0')
    if a.action=='build':
        if out.exists():raise SystemExit('输出须全新独立目录')
        out.mkdir(mode=0o700);app=out/'app';app.mkdir();(out/'settings.gradle.kts').write_text('pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositories { google(); mavenCentral() } }\nrootProject.name="HarmoniaSlotOwnerFixture"\ninclude(":app")\n')
        (out/'build.gradle.kts').write_text('plugins { id("com.android.application") version "9.1.0" apply false; id("org.jetbrains.kotlin.android") version "2.4.0" apply false }\n')
        (out/'gradle.properties').write_text('org.gradle.jvmargs=-Xmx2G\nandroid.useAndroidX=true\n')
        (out/'local.properties').write_text('sdk.dir='+str(sdk)+'\n')
        # 新合成debug签名，仅本隔离目录；不访问宿主/旧debug钥。
        key=out/'synthetic-debug.jks'
        subprocess.run([str(java/'bin/keytool'),'-genkeypair','-keystore',str(key),'-storepass','synthetic-local-only','-keypass','synthetic-local-only','-alias','synthetic','-keyalg','RSA','-keysize','2048','-validity','2','-dname','CN=Harmonia Synthetic Slot Test'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        embedding=list((Path.home()/'.gradle/caches/modules-2/files-2.1/io.flutter/flutter_embedding_debug/1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0').glob('*/*.jar'));assert len(embedding)==1
        libs=app/'libs';libs.mkdir();shutil.copy2(embedding[0],libs/'flutter-compile-only.jar');shutil.copy2(A/'artifacts/harmonia-slot-owner-jni-test-v2.aar',libs/'slot-jni-test.aar')
        (app/'build.gradle.kts').write_text('plugins { id("com.android.application") }\nandroid { namespace="org.harmoniavault.slotownerfixture"; compileSdk=36; defaultConfig { applicationId="org.harmoniavault.slotownerfixture"; minSdk=30; targetSdk=34; testInstrumentationRunner="androidx.test.runner.AndroidJUnitRunner"; ndk { abiFilters.add("arm64-v8a") } }; signingConfigs { create("synthetic") { storeFile=file("../synthetic-debug.jks"); storePassword="synthetic-local-only"; keyAlias="synthetic"; keyPassword="synthetic-local-only" } }; buildTypes { getByName("debug") { signingConfig=signingConfigs.getByName("synthetic") } }; compileOptions { sourceCompatibility=JavaVersion.VERSION_17; targetCompatibility=JavaVersion.VERSION_17 } }\n dependencies { implementation(files("libs/slot-jni-test.aar")); implementation(files("libs/flutter-compile-only.jar")); androidTestImplementation("androidx.test:runner:1.7.0"); androidTestImplementation("androidx.annotation:annotation:1.9.1"); androidTestImplementation("androidx.tracing:tracing:1.2.0"); androidTestImplementation("junit:junit:4.13.2") }\n')
        main=app/'src/main';main.mkdir(parents=True);(main/'AndroidManifest.xml').write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.USE_BIOMETRIC"/><application android:label="Harmonia Slot Test" android:allowBackup="false"><activity android:name="org.harmoniavault.harmonia_mobile.nativebridge.SlotOwnerFixtureActivity" android:exported="false"/><service android:name="org.harmoniavault.harmonia_mobile.nativebridge.SlotOwnerProbeService" android:process=":slot_owner_probe" android:exported="false"/></application></manifest>')
        native=mobile/'android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile/nativebridge';shutil.copytree(native,main/'kotlin/org/harmoniavault/harmonia_mobile/nativebridge')
        shutil.copy2(mobile/'tool/native-slot-owner-fixture/SlotOwnerProbeService.kt',main/'kotlin/org/harmoniavault/harmonia_mobile/nativebridge/SlotOwnerProbeService.kt')
        shutil.copy2(mobile/'tool/native-slot-owner-fixture/SlotOwnerFixtureActivity.kt',main/'kotlin/org/harmoniavault/harmonia_mobile/nativebridge/SlotOwnerFixtureActivity.kt')
        tests=app/'src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/nativebridge';tests.mkdir(parents=True);shutil.copy2(mobile/'android/app/src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeSlotOwnerAndroidTest.kt',tests/'NativeSlotOwnerAndroidTest.kt')
        gradle=list((Path.home()/'.gradle/wrapper/dists/gradle-9.3.1-all').glob('*/gradle-9.3.1/bin/gradle'));assert len(gradle)==1
        env=os.environ.copy();env['JAVA_HOME']=str(java);start=time.monotonic()
        r=subprocess.run([str(gradle[0]),'--offline','--no-daemon','--console=plain',':app:assembleDebug',':app:assembleDebugAndroidTest'],cwd=out,env=env,capture_output=True,text=True);(out/'build.log').write_text(r.stdout+r.stderr)
        manifest={'status':'PASS' if r.returncode==0 else 'FAIL','buildSeconds':round(time.monotonic()-start,3),'runtime':'UNRUN','scope':'isolated 6-case Android store/JNI; no Flutter/cloud/DAG/PIN-auth; six native cases include real system create cancel+interrupted intent resume','inputs':{str(f.relative_to(A)):sha(f) for f in sorted([*native.rglob('*.kt'),mobile/'android/app/src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeSlotOwnerAndroidTest.kt',* (mobile/'tool/native-slot-owner-fixture').glob('*.kt'),Path(__file__).resolve(),A/'core-go/test/nativeatomicfixture/fixture.go'])},'apk':{str(f.relative_to(out)):sha(f) for f in out.rglob('*.apk')},'testAAR':sha(A/'artifacts/harmonia-slot-owner-jni-test-v2.aar')}
        (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('buildStatus='+manifest['status']);raise SystemExit(r.returncode)
    # 仅父任务review精确manifest后显式run；本文件准备阶段不触ADB。
    if a.serial!='emulator-5580' or not a.reviewed_manifest or not a.expected_emulator_pid or sha(out/'run-manifest.json')!=a.reviewed_manifest:raise SystemExit('缺少精确已审manifest/serial/本人AVD PID')
    manifest=json.loads((out/'run-manifest.json').read_text());assert manifest['status']=='PASS'
    assert sha(out/'manifest.json')==manifest['compiledBuildManifestSHA256']
    for name,h in manifest['apk'].items():assert sha(out/name)==h
    for name,h in manifest['inputs'].items():assert sha(A/name)==h
    adb=sdk/'platform-tools/adb';pkgs=['org.harmoniavault.slotownerfixture','org.harmoniavault.slotownerfixture.test']
    class FixedFailure(Exception):pass
    def require(ok,code):
        if not ok:raise FixedFailure(code)
    def call(args,timeout=20):
        try:return subprocess.run([str(adb),'-s',a.serial,*args],capture_output=True,text=True,timeout=timeout)
        except Exception:raise FixedFailure('SDK_COMMAND_FAILED') from None
    def sdk_secure():
        r=call(['shell','am','instrument','-w','-r','-e','class','org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotSecurityProbeTest',pkgs[1]+'/androidx.test.runner.AndroidJUnitRunner'])
        values=re.findall(r'^INSTRUMENTATION_STATUS: SDK_DEVICE_SECURE=(true|false)$',r.stdout,re.M)
        require(r.returncode==0 and 'OK (1 test)' in r.stdout and len(values)==1,'SDK_SECURITY_STATE_UNKNOWN')
        return values[0]=='true'
    result={'runtime':'UNRUN','stage':'baseline','credentialInputs':0,'credentialCancellations':0,'packagesCleaned':False,'SDKFinallyNoSecure':False}
    def save(): (out/'runtime-result.json').write_text(json.dumps(result,indent=2)+'\n')
    # 只读本人精确PID公开启动参数；不读宿主环境、账号或凭据。
    identity=subprocess.run(['ps','-p',str(a.expected_emulator_pid),'-o','pid=,command='],capture_output=True,text=True)
    require(identity.returncode==0 and len(identity.stdout.splitlines())==1 and 'qemu-system-aarch64' in identity.stdout and '-avd harmonia-test-api34' in identity.stdout and '-port 5580' in identity.stdout,'VM_IDENTITY_REJECTED')
    identity=None
    require(call(['shell','getprop','ro.kernel.qemu']).stdout.strip()=='1' and call(['shell','getprop','ro.build.version.sdk']).stdout.strip()=='34','VM_PROFILE_REJECTED')
    baseline=set(call(['shell','pm','list','packages']).stdout.splitlines());require(all('package:'+pkg not in baseline for pkg in pkgs),'TARGET_PACKAGE_EXISTS')
    installed=[];pin=None;attempted=False;instrument=None;log=None;credential_cleared=True;raw=[];reader=None
    try:
        for name in sorted(manifest['apk'],key=lambda s:'androidTest' in s):
            r=call(['install',str(out/name)],timeout=60);require(r.returncode==0 and 'Success' in r.stdout,'INSTALL_FAILED');installed.append(name)
        require(not sdk_secure(),'BASELINE_HAS_SYSTEM_CREDENTIAL')
        result['SDKBaselineNoSecure']=True;result['stage']='officialSyntheticCredentialSetup';save()
        pin=''.join(str(secrets.randbelow(10)) for _ in range(8));attempted=True;credential_cleared=False
        # 仅正常官方合成测试准备；PIN只RAM传argv，输出/异常/进程args均不记录。
        setup=call(['shell','locksettings','set-pin','--user','0',pin]);require(setup.returncode==0,'CREDENTIAL_SETUP_FAILED');setup=None
        require(sdk_secure(),'CREDENTIAL_SETUP_UNCONFIRMED');result['SDKSecureVerified']=True
        log=subprocess.Popen([str(adb),'-s',a.serial,'logcat','-T','1','-v','brief','HarmoniaSlotTest:I','*:S'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        events=queue.Queue()
        def read_log():
            for line in log.stdout:
                for stage in ['cancel-create','retry-create']:
                    if 'AWAIT_SLOT_AUTH:'+stage in line:events.put(stage)
        threading.Thread(target=read_log,daemon=True).start()
        result['stage']='sixNativeCases';result['runtime']='RUNNING';save();start=time.monotonic()
        raw=[]
        instrument=subprocess.Popen([str(adb),'-s',a.serial,'shell','am','instrument','-w','-r','-e','class','org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotOwnerAndroidTest',pkgs[1]+'/androidx.test.runner.AndroidJUnitRunner'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        def read_instrument():
            for line in instrument.stdout:raw.append(line)
        reader=threading.Thread(target=read_instrument,daemon=True);reader.start();seen=set()
        while instrument.poll() is None:
            require(time.monotonic()-start<150,'INSTRUMENTATION_TIMEOUT')
            try:stage=events.get(timeout=.2)
            except queue.Empty:continue
            require(stage not in seen,'DUPLICATE_AUTH_STAGE');seen.add(stage)
            time.sleep(.9)
            if stage=='cancel-create':
                require(call(['shell','input','keyevent','KEYCODE_BACK']).returncode==0,'CANCEL_INPUT_FAILED');time.sleep(.2)
                require(call(['shell','input','keyevent','KEYCODE_BACK']).returncode==0,'CANCEL_INPUT_FAILED');result['credentialCancellations']+=1
            else:
                require(call(['shell','input','text',pin]).returncode==0,'CREDENTIAL_INPUT_FAILED')
                require(call(['shell','input','keyevent','66']).returncode==0,'CREDENTIAL_INPUT_FAILED');result['credentialInputs']+=1
            save()
        reader.join(timeout=3);require(not reader.is_alive(),'RESULT_DRAIN_UNKNOWN')
        text=''.join(raw);(out/'instrumentation.log').write_text(text)
        require(instrument.returncode==0 and 'OK (6 tests)' in text,'SIX_NATIVE_CASES_FAILED')
        require(seen=={'cancel-create','retry-create'} and result['credentialInputs']==1 and result['credentialCancellations']==1,'AUTH_STAGE_COUNT_MISMATCH')
        result.update(runtime='PASS',stage='complete',seconds=round(time.monotonic()-start,3))
    except FixedFailure as failure:result.update(runtime='FAIL',error=str(failure))
    except Exception:result.update(runtime='FAIL',error='HOST_REJECTED')
    finally:
        if instrument is not None and instrument.poll() is None:
            try:
                call(['shell','am','force-stop',pkgs[0]]);instrument.wait(timeout=15)
            except Exception:result['workerDrain']='unknown'
        if reader is not None:
            reader.join(timeout=3)
            if reader.is_alive():result['workerDrain']='unknown'
        if raw:(out/'instrumentation.log').write_text(''.join(raw))
        if log is not None:
            try:log.terminate();log.wait(timeout=5)
            except Exception:result['logDrain']='unknown'
        if attempted:
            try:
                clear=call(['shell','locksettings','clear','--old',pin,'--user','0']);result['officialClearExit']=clear.returncode;clear=None
                credential_cleared=not sdk_secure();result['SDKFinallyNoSecure']=credential_cleared
            except Exception:result['cleanupBlocker']='SYSTEM_CREDENTIAL_STATE_UNKNOWN'
        else:
            try:result['SDKFinallyNoSecure']=len(installed)==2 and not sdk_secure()
            except Exception:result['SDKFinallyNoSecure']=False
        if not credential_cleared or result.get('cleanupBlocker') or result.get('workerDrain')=='unknown':
            result['cleanupBlocker']='SYSTEM_CREDENTIAL_OR_WORKER_CLEANUP_BLOCKED';save()
            print(json.dumps({'status':'BLOCKED','stage':'ownedCredentialCleanup','pinRetainedOnlyInRAM':True}),flush=True)
            # 不抛出带secret argv的异常、不杀owner或丢RAM；须父任务处理真实未知状态。
            while True:time.sleep(30)
        pin=None
        for pkg in reversed(pkgs):
            if 'package:'+pkg in call(['shell','pm','list','packages']).stdout.splitlines():call(['uninstall',pkg])
        remaining=set(call(['shell','pm','list','packages']).stdout.splitlines())
        result['packagesCleaned']=all('package:'+pkg not in remaining for pkg in pkgs)
        result['baselinePackageSetPreserved']=remaining==baseline
        save();print(json.dumps(result))
    raise SystemExit(0 if result['runtime']=='PASS' and result['packagesCleaned'] and result['baselinePackageSetPreserved'] and result['SDKFinallyNoSecure'] else 1)
if __name__=='__main__':main()
