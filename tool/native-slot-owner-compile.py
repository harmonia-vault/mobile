from pathlib import Path
import argparse,subprocess,zipfile,json,time,hashlib
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--jni',action='store_true');a=p.parse_args()
A=a.candidate.resolve();out=a.output.resolve();out.mkdir(exist_ok=False)
mobile=A/'mobile';cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(name,v):
 f=list((cache/name/v).glob('*/*.jar'));assert len(f)==1,(name,v);return str(f[0])
def where(name):return Path(subprocess.check_output(['mise','where',name],cwd=mobile,text=True).strip())
java=where('java@temurin-17.0.16+8')/'bin/java';sdk=where('android-sdk@19.0')/'platforms/android-36/android.jar'
compiler=[jar(n,v) for n,v in [('org.jetbrains.kotlin/kotlin-compiler-embeddable','2.4.0'),('org.jetbrains.kotlin/kotlin-stdlib','2.4.0'),('org.jetbrains.kotlin/kotlin-script-runtime','2.4.0'),('org.jetbrains.kotlin/kotlin-reflect','1.6.10'),('org.jetbrains.kotlin/kotlin-daemon-embeddable','2.4.0'),('org.jetbrains.kotlin/kotlin-build-tools-api','2.4.0'),('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm','1.8.0'),('org.jetbrains/annotations','13.0')]]
with zipfile.ZipFile(A/('artifacts/harmonia-slot-owner-jni-test-v2.aar' if a.jni else 'artifacts/harmonia-slot-owner-v2.aar')) as z:(out/'go.jar').write_bytes(z.read('classes.jar'))
stdlib=jar('org.jetbrains.kotlin/kotlin-stdlib','2.4.0')
embedding=jar('io.flutter/flutter_embedding_debug','1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0')
root=mobile/'android/app/src/main/kotlin/org/harmoniavault/harmonia_mobile/nativebridge'
sources=sorted(root.rglob('*.kt'))
test=mobile/'android/app/src/test/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/SlotSnapshotLeaseHostTest.kt';sources+=[test]
cp=[stdlib,str(sdk),str(out/'go.jar'),embedding]
if a.jni:
 sources += [mobile/'android/app/src/androidTest/kotlin/org/harmoniavault/harmonia_mobile/nativebridge/NativeSlotOwnerAndroidTest.kt',mobile/'tool/native-slot-owner-fixture/SlotOwnerProbeService.kt',mobile/'tool/native-slot-owner-fixture/SlotOwnerFixtureActivity.kt']
 monitor=list((cache/'androidx.test/monitor/1.8.0').glob('*/*.aar'));assert len(monitor)==1
 with zipfile.ZipFile(monitor[0]) as z:(out/'monitor.jar').write_bytes(z.read('classes.jar'))
 cp += [jar('junit/junit','4.13.2'),str(out/'monitor.jar')]
t=time.monotonic();command=[str(java),'-cp',':'.join(compiler),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','17','-classpath',':'.join(cp),'-d',str(out/'candidate.jar'),*map(str,sources)]
r=subprocess.run(command,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
result={'compileExit':r.returncode,'seconds':round(time.monotonic()-t,3),'sources':{str(s.relative_to(mobile)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources},'runtime':'UNRUN Android/JNI/Keystore/device/CAS'}
if r.returncode==0:
 t=time.monotonic();h=subprocess.run([str(java),'-cp',str(out/'candidate.jar')+':'+stdlib,'org.harmoniavault.harmonia_mobile.nativebridge.SlotSnapshotLeaseHostTest'],capture_output=True,text=True);(out/'host.log').write_text(h.stdout+h.stderr);result.update(hostExit=h.returncode,hostSeconds=round(time.monotonic()-t,3));print(h.stdout,end='')
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('compileExit='+str(r.returncode));print(r.stderr);raise SystemExit(r.returncode or result.get('hostExit',0))
