#!/usr/bin/env python3
"""仅隔离AVD：连续恢复三独立进程与正式CLI4；调用者准备合成PIN/APK/HTTPS。"""
from pathlib import Path
import argparse, base64, json, queue, subprocess, threading, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True)
options = parser.parse_args()
if not options.serial.startswith('emulator-'):
    raise SystemExit('仅允许显式隔离模拟器')
mobile = Path(__file__).resolve().parent.parent
workspace = mobile.parent
sdk = subprocess.run(['mise', 'where', 'android-sdk@19.0'], cwd=mobile,
                     check=True, capture_output=True, text=True).stdout.strip()
args = [str(Path(sdk)/'platform-tools/adb'), '-s', options.serial]

def adbrun(*tail, checked=True):
    return subprocess.run(args+list(tail), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=checked).stdout

if adbrun('shell', 'getprop', 'ro.kernel.qemu').decode().strip() != '1':
    raise SystemExit('必须使用合成模拟器')
package = 'org.harmoniavault.harmonia_mobile.nativefixture'
socket_name = 'harmonia-native-test-recovery-v1'
port = adbrun('forward', 'tcp:0', 'localabstract:'+socket_name).decode().strip()
fixture = mobile/'build/native/recovery-fixture'
ca = base64.b64encode((fixture/'ca.pem').read_bytes()).decode()
log = subprocess.Popen(args+['logcat', '-T', '1', '-v', 'brief', 'HarmoniaNativeTest:I', '*:S'],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
lines = queue.Queue()
def log_reader():
    for line in log.stdout:
        lines.put(line.strip())
threading.Thread(target=log_reader, daemon=True).start()
controllers = []; collectors = []; results = []; stages = []
auths = 0; cancelled = 0; instrument = None; out = None
runtime = mobile/'build/native/recovery-runtime.json'
methods = [
    'test01OldCodeOwnerPrePostSealFailureAndUnknownTransition',
    'test02NewCodeAfterRealProcessStopAndCert4FinalSealFailure',
    'test03OriginalCert4RetryTrustedEAndExplicitCLI4',
]

def launch(binary, extra, password=False):
    command = [str(workspace/'core-go/.build/mobilebridge'/binary),
               '--endpoint', 'https://127.0.0.1:4443', '--ca-file', str(fixture/'ca.pem'),
               '--port', port]+extra
    p = subprocess.Popen(command, stdin=subprocess.PIPE if password else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if password:
        p.stdin.write(b'synthetic-cross-password-only\n'); p.stdin.close()
    def collect():
        raw = p.stdout.read(); code = p.wait()
        # 控制器只输出固定阶段/错误类别；完整恢复码/短码均仅其RAM或socket。
        results.append({'controller': binary, 'exit': code})
        print(binary, 'exit', code, raw.decode(errors='replace').strip(), flush=True)
    t = threading.Thread(target=collect, daemon=True); t.start()
    controllers.append(p); collectors.append(t)

try:
    for index, method in enumerate(methods, 1):
        output = mobile/f'build/native/recovery-phase{index}.txt'
        out = output.open('w')
        instrument = subprocess.Popen(args+['shell', 'am', 'instrument', '-w', '-e', 'class',
             'org.harmoniavault.harmonia_mobile.nativebridge.NativeRecoveryIntegrationTest#'+method,
             '-e', 'syntheticCA', ca, '-e', 'nativeSocket', socket_name,
             package+'.test/androidx.test.runner.AndroidJUnitRunner'], stdout=out, stderr=out)
        deadline = time.monotonic()+260; pid = ''
        while instrument.poll() is None:
            if time.monotonic() > deadline:
                raise RuntimeError('focused recovery phase timeout')
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                continue
            if 'AWAIT_RECOVERY_AUTH:' in line:
                phase = line.split('AWAIT_RECOVERY_AUTH:', 1)[1]
                auths += 1; print('system authentication stage:', phase, flush=True)
                if not pid:
                    pid = adbrun('shell', 'pidof', package, checked=False).decode().strip()
                time.sleep(.9)
                if phase == 'cancel-recovery-owner':
                    adbrun('shell', 'input', 'keyevent', '4'); time.sleep(.2)
                    adbrun('shell', 'input', 'keyevent', '4'); cancelled += 1
                else:
                    adbrun('shell', 'input', 'text', '24681357')
                    adbrun('shell', 'input', 'keyevent', '66')
            elif 'RECOVERY_REGISTRATION_DIAGNOSTIC:' in line or 'EXPECTED_RECOVERY_SAVE_BOUNDARY:' in line:
                print(line.split('HarmoniaNativeTest', 1)[-1], flush=True)
            elif 'AWAIT_RECOVERY_ROOT_SOCKET:' in line:
                if controllers:
                    raise RuntimeError('duplicate root fixture request')
                launch('recoverycontroller', [])
            elif 'AWAIT_RECOVERY_CLI_SOCKET:' in line:
                if len(controllers) != 1:
                    raise RuntimeError('unexpected CLI4 fixture request')
                launch('crosscontroller', ['--native-ready', '--cli',
                    str(workspace/'core-go/.build/mobilebridge/crossfixture-harmonia'),
                    '--certificate-version', '4'], password=True)
        status = instrument.wait(); out.close(); out = None
        result = output.read_text(); print(result, flush=True)
        stages.append({'phase': index, 'method': method, 'exit': status,
                       'pid': pid, 'passed': 'OK (1 test)' in result})
        runtime.write_text(json.dumps({'phases': stages, 'auths': auths, 'cancelled': cancelled, 'controllers': results}, indent=2)+'\n')
        if status != 0 or 'OK (1 test)' not in result:
            raise RuntimeError('recovery focused phase failed; later phases UNRUN')
        if index < 3:
            adbrun('shell', 'am', 'force-stop', package)
            after = adbrun('shell', 'pidof', package, checked=False).decode().strip()
            stages[-1]['forceStopped'] = not after
            if after:
                raise RuntimeError('synthetic process still running after force-stop')
            print('synthetic app process stopped after phase', index, flush=True)
    for p in controllers:
        p.wait(timeout=20)
    for t in collectors:
        t.join(timeout=20)
    if len(results) != 2 or any(item['exit'] for item in results):
        raise RuntimeError('recovery root/compiled CLI4 controllers did not both pass')
    if len({item['pid'] for item in stages}) != 3 or any(not item['pid'] for item in stages):
        raise RuntimeError('three independent app process IDs not confirmed')
    print('continuous recovery focused 3/3 PASS; two actual process stops; system prompts', auths, 'cancelled', cancelled, flush=True)
finally:
    for p in controllers:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    if instrument is not None and instrument.poll() is None:
        adbrun('shell', 'am', 'force-stop', package, checked=False)
        instrument.wait(timeout=10)
    log.terminate(); log.wait(timeout=10)
    adbrun('forward', '--remove', 'tcp:'+port)
    if out is not None: out.close()
    runtime.write_text(json.dumps({'phases': stages, 'auths': auths, 'cancelled': cancelled, 'controllers': results}, indent=2)+'\n')
