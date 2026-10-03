from pathlib import Path
import subprocess, threading, time, queue, base64, argparse
parser=argparse.ArgumentParser(description="仅隔离AVD的native管理合成验收；调用者准备本轮PIN/APK/HTTPSfixture")
parser.add_argument('--serial',required=True)
options=parser.parse_args()
if not options.serial.startswith('emulator-'): raise SystemExit('仅允许显式隔离模拟器')
mobile=Path(__file__).resolve().parent.parent
workspace=mobile.parent
sdk=subprocess.run(['mise','where','android-sdk@19.0'],cwd=mobile,check=True,capture_output=True,text=True).stdout.strip()
args=[str(Path(sdk)/'platform-tools/adb'),'-s',options.serial]
def adbrun(*tail):return subprocess.run(args+list(tail),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
if adbrun('shell','getprop','ro.kernel.qemu').decode().strip()!='1':raise SystemExit('必须使用合成模拟器')
socket_name='harmonia-native-test-management-v1'
port=adbrun('forward','tcp:0','localabstract:'+socket_name).decode().strip()
ca=base64.b64encode((mobile/'build/native/management-fixture/ca.pem').read_bytes()).decode()
# 只读取固定合成instrumentation tag，短码始终只在native/socket内存。
log=subprocess.Popen(args+['logcat','-T','1','-v','brief','HarmoniaNativeTest:I','*:S'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
lines=queue.Queue()
def log_reader():
 for line in log.stdout:lines.put(line.strip())
threading.Thread(target=log_reader,daemon=True).start()
output=mobile/'build/native/management-cross-runtime.txt'
out=output.open('w')
instrument=subprocess.Popen(args+['shell','am','instrument','-w','-e','class','org.harmoniavault.harmonia_mobile.nativebridge.NativeManagementIntegrationTest','-e','syntheticCA',ca,'-e','nativeSocket',socket_name,'org.harmoniavault.harmonia_mobile.nativefixture.test/androidx.test.runner.AndroidJUnitRunner'],stdout=out,stderr=out)
peers=[];results=[];collectors=[];auths=0;deadline=time.monotonic()+400
try:
 while instrument.poll() is None:
  if time.monotonic()>deadline:raise RuntimeError('focused instrumentation timeout')
  try:line=lines.get(timeout=1)
  except queue.Empty:continue
  if 'AWAIT_MANAGEMENT_AUTH:' in line:
   phase=line.split('AWAIT_MANAGEMENT_AUTH:',1)[1];auths+=1;print('system authentication stage:',phase,flush=True)
   time.sleep(.9);adbrun('shell','input','text','24681357');adbrun('shell','input','keyevent','66')
  elif 'AWAIT_MANAGEMENT_PEER_SOCKET:' in line:
   if peers:raise RuntimeError('duplicate synthetic peer request')
   command=[str(workspace/'core-go/.build/mobilebridge/managementpeer'),'--endpoint','https://127.0.0.1:4443','--ca-file',str(mobile/'build/native/management-fixture/ca.pem'),'--port',port]
   process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   process.stdin.write(b'synthetic-cross-password-only\n');process.stdin.close()
   def collect(p):
    raw=p.stdout.read();code=p.wait();results.append(code);print('synthetic Go peer exit',code,raw.decode(errors='replace').strip(),flush=True)
   collector=threading.Thread(target=collect,args=(process,),daemon=True);collector.start();collectors.append(collector);peers.append(process)
 print('instrumentation process exit',instrument.wait(),'auth prompts',auths,flush=True)
 out.flush();result=output.read_text();print(result,flush=True)
 for p in peers:p.wait(timeout=10)
 for collector in collectors:collector.join(timeout=10)
 if 'OK (1 test)' not in result or len(results)!=1 or any(results):raise RuntimeError('native管理/真实Go对端 focused未全部通过')
finally:
 for p in peers:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 if instrument.poll() is None:
  subprocess.run(args+['shell','am','force-stop','org.harmoniavault.harmonia_mobile.nativefixture'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  instrument.wait(timeout=10)
 log.terminate();log.wait(timeout=10)
 adbrun('forward','--remove','tcp:'+port);out.close()
