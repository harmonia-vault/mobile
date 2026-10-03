#!/usr/bin/env python3
"""隔离AVD合成账号四意图：真实强认证和两次force-stop，调用者负责PIN/包/HTTPS最终清理。"""
from pathlib import Path
import argparse,base64,json,queue,subprocess,threading,time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial',required=True)
options=parser.parse_args()
if not options.serial.startswith('emulator-'):raise SystemExit('仅允许显式隔离模拟器')
mobile=Path(__file__).resolve().parent.parent
sdk=subprocess.run(['mise','where','android-sdk@19.0'],cwd=mobile,check=True,capture_output=True,text=True).stdout.strip()
args=[str(Path(sdk)/'platform-tools/adb'),'-s',options.serial]
def adbrun(*tail,checked=True):return subprocess.run(args+list(tail),check=checked,capture_output=True).stdout
if adbrun('shell','getprop','ro.kernel.qemu').decode().strip()!='1':raise SystemExit('必须使用合成模拟器')
package='org.harmoniavault.harmonia_mobile.nativefixture'
ca=base64.b64encode((mobile/'build/native/account-fixture/ca.pem').read_bytes()).decode()
log=subprocess.Popen(args+['logcat','-T','1','-v','brief','HarmoniaNativeTest:I','*:S'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
lines=queue.Queue()
def reader():
 for line in log.stdout:lines.put(line.strip())
threading.Thread(target=reader,daemon=True).start()
methods=['test01LoginDoesNotTrustAndOriginalVariablePending','test02OriginalVariableRetryAfterProcessDeathAndEnvironmentPending','test03OriginalEnvironmentRetryRestoreAndLogout']
stages=[];auths=0;instrument=None;out=None
runtime=mobile/'build/native/account-runtime.json'
try:
 for index,method in enumerate(methods,1):
  output=mobile/f'build/native/account-phase{index}.txt';out=output.open('w')
  instrument=subprocess.Popen(args+['shell','am','instrument','-w','-e','class','org.harmoniavault.harmonia_mobile.nativebridge.NativeAccountIntegrationTest#'+method,'-e','syntheticCA',ca,package+'.test/androidx.test.runner.AndroidJUnitRunner'],stdout=out,stderr=out)
  deadline=time.monotonic()+200;pid=''
  while instrument.poll() is None:
   if time.monotonic()>deadline:raise RuntimeError('account focused phase timeout')
   try:line=lines.get(timeout=1)
   except queue.Empty:continue
   if 'AWAIT_ACCOUNT_AUTH:' in line:
    phase=line.split('AWAIT_ACCOUNT_AUTH:',1)[1];auths+=1
    print('system authentication stage:',phase,flush=True)
    if not pid:pid=adbrun('shell','pidof',package,checked=False).decode().strip()
    time.sleep(.9);adbrun('shell','input','text','24681357');adbrun('shell','input','keyevent','66')
   elif 'ACCOUNT_ENV_DIAGNOSTIC:' in line:print(line.split('ACCOUNT_ENV_DIAGNOSTIC:',1)[1],flush=True)
  status=instrument.wait();out.close();out=None
  result=output.read_text();print(result,flush=True)
  stages.append({'phase':index,'exit':status,'pid':pid,'passed':'OK (1 test)' in result})
  runtime.write_text(json.dumps({'phases':stages,'auths':auths},indent=2)+'\n')
  if status or 'OK (1 test)' not in result:raise RuntimeError('account focused failed; later phases UNRUN')
  if index<3:
   adbrun('shell','am','force-stop',package)
   if adbrun('shell','pidof',package,checked=False).decode().strip():raise RuntimeError('synthetic process still running')
   stages[-1]['forceStopped']=True
   print('synthetic account process stopped after phase',index,flush=True)
 if len({item['pid'] for item in stages})!=3 or any(not item['pid'] for item in stages):raise RuntimeError('independent process IDs not confirmed')
 print('account focused3/3 PASS; two real process stops; system prompts',auths,flush=True)
finally:
 if instrument is not None and instrument.poll() is None:
  adbrun('shell','am','force-stop',package,checked=False);instrument.wait(timeout=10)
 log.terminate();log.wait(timeout=10)
 if out is not None:out.close()
 runtime.write_text(json.dumps({'phases':stages,'auths':auths},indent=2)+'\n')
