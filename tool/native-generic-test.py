from pathlib import Path
import subprocess,threading,time,queue,base64,sys,os
import argparse
parser=argparse.ArgumentParser(description="仅隔离AVD的native cert3 generic合成验收，调用者先准备测试PIN、APK、fixture")
parser.add_argument('--serial',required=True)
options=parser.parse_args()
if not options.serial.startswith('emulator-'):raise SystemExit('仅允许显式隔离模拟器')
mobile=Path(__file__).resolve().parent.parent
workspace=mobile.parent
sdk=subprocess.run(['mise','where','android-sdk@19.0'],cwd=mobile,check=True,capture_output=True,text=True).stdout.strip()
adb=str(Path(sdk)/'platform-tools/adb')
args=[adb,'-s',options.serial]
if subprocess.run(args+['shell','getprop','ro.kernel.qemu'],check=True,capture_output=True,text=True).stdout.strip()!='1':raise SystemExit('必须使用合成模拟器')
# This script reads only the explicitly scoped instrumentation tag. Short code never appears here.
socket_name='harmonia-native-test-generic-v3'
def adbrun(*tail):return subprocess.run(args+list(tail),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
port=adbrun('forward','tcp:0','localabstract:'+socket_name).decode().strip()
ca=base64.b64encode((mobile/'build/native/generic-fixture/ca.pem').read_bytes()).decode()
log= subprocess.Popen(args+['logcat','-T','1','-v','brief','HarmoniaNativeTest:I','*:S'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
lines=queue.Queue()
def log_reader():
 for line in log.stdout: lines.put(line.strip())
threading.Thread(target=log_reader,daemon=True).start()
output=mobile/'build/native/generic-cross-runtime.txt'
out=output.open('w')
instrument=subprocess.Popen(args+['shell','am','instrument','-w','-e','class','org.harmoniavault.harmonia_mobile.nativebridge.NativeGenericIntegrationTest','-e','syntheticCA',ca,'-e','nativeSocket',socket_name,'org.harmoniavault.harmonia_mobile.nativefixture.test/androidx.test.runner.AndroidJUnitRunner'],stdout=out,stderr=out)
controllers=[];controller_results=[];collectors=[];auths=0;cancelled=0;deadline=time.monotonic()+400
try:
 while instrument.poll() is None:
  if time.monotonic()>deadline:raise RuntimeError('focused instrumentation timeout')
  try:line=lines.get(timeout=1)
  except queue.Empty:continue
  if 'AWAIT_GENERIC_AUTH:' in line:
   phase=line.split('AWAIT_GENERIC_AUTH:',1)[1];auths+=1;print('system authentication stage:',phase,flush=True)
   time.sleep(.9)
   if phase=='cancel-approval':
    adbrun('shell','input','keyevent','4');time.sleep(.2);adbrun('shell','input','keyevent','4');cancelled+=1
   else:
    adbrun('shell','input','text','24681357');adbrun('shell','input','keyevent','66')
  elif 'AWAIT_GENERIC_ROOT_SOCKET:' in line:
   command=[str(workspace/'core-go/.build/mobilebridge/genericcontroller'),'--endpoint','https://127.0.0.1:4443','--ca-file',str(mobile/'build/native/generic-fixture/ca.pem'),'--port',port]
   process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   def collect_root(p):
    raw=p.stdout.read();code=p.wait();controller_results.append(code);print('root controller exit',code,raw.decode(errors='replace').strip(),flush=True)
   collector=threading.Thread(target=collect_root,args=(process,),daemon=True);collector.start();collectors.append(collector);controllers.append(process)
  elif 'AWAIT_LOCAL_PAIRING_SOCKET:' in line:
   stage=line.split('AWAIT_LOCAL_PAIRING_SOCKET:',1)[1];print('local compiled CLI stage:',stage,flush=True)
   controller=workspace/'core-go/.build/mobilebridge/crosscontroller'
   cli=workspace/'core-go/.build/mobilebridge/crossfixture-harmonia'
   command=[str(controller),'--native-ready','--cli',str(cli),'--endpoint','https://127.0.0.1:4443','--ca-file',str(mobile/'build/native/generic-fixture/ca.pem'),'--port',port,'--certificate-version','3']
   if 'save-failure' in stage:command+=['--expect-rejected']
   process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   process.stdin.write(b'synthetic-cross-password-only\n');process.stdin.close()
   def collect(p,label):
    raw=p.stdout.read();code=p.wait();controller_results.append(code);print('controller',label,'exit',code,raw.decode(errors='replace').strip(),flush=True)
   collector=threading.Thread(target=collect,args=(process,stage),daemon=True);collector.start();collectors.append(collector);controllers.append(process)
 print('instrumentation process exit',instrument.wait(),'auth prompts',auths,'cancelled',cancelled,flush=True)
 out.flush();result=output.read_text();print(result,flush=True)
 for p in controllers:p.wait(timeout=10)
 for collector in collectors:collector.join(timeout=10)
 if 'OK (1 test)' not in result or len(controller_results)!=2 or any(controller_results):raise RuntimeError('原生/compiled CLI focused验收未全部通过')
finally:
 for p in controllers:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 if instrument.poll() is None:
  subprocess.run(args+['shell','am','force-stop','org.harmoniavault.harmonia_mobile.nativefixture'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  instrument.wait(timeout=10)
 log.terminate()
 adbrun('forward','--remove','tcp:'+port)
 out.close()
