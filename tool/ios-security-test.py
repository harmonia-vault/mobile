#!/usr/bin/env python3
"""仅运行显式选择、专有名称的 Simulator 与本项目独立测试 bundle。"""
import argparse, json, pathlib, subprocess, time
parser=argparse.ArgumentParser()
parser.add_argument('--device',required=True)
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
app=root/'build/ios-security/HarmoniaSecurity.app'
bundle='org.harmoniavault.ios.security.synthetic.t20261003'
def run(*command):return subprocess.check_output(command,text=True,timeout=30).strip()
devices=json.loads(run('xcrun','simctl','list','devices','available','--json'))['devices']
device=next((item for items in devices.values() for item in items if item['udid']==args.device),None)
if not device or not device['name'].startswith('Harmonia-iOS-Synthetic-') or device['state']!='Booted':
    raise SystemExit('必须显式选择已启动的 Harmonia-iOS-Synthetic- 隔离设备；不重置或操作旧设备。')
runid=(app/'HarmoniaHarnessRunID.txt').read_text()
run('xcrun','simctl','install',args.device,str(app))
container=pathlib.Path(run('xcrun','simctl','get_app_container',args.device,bundle,'data'))
run('xcrun','simctl','launch','--terminate-running-process',args.device,bundle)
result=container/'Documents/native-result.json'
started=time.monotonic()
while time.monotonic()-started<60:
    if result.exists():
        value=json.loads(result.read_text())
        if value.get('runId')==runid:
            body=json.dumps(value,ensure_ascii=False,indent=2)+'\n'
            evidence=root/'build/ios-security/result.json';evidence.write_text(body)
            (evidence.parent/('result-'+runid.strip()+'.json')).write_text(body)
            print(json.dumps(value,ensure_ascii=False,indent=2))
            raise SystemExit(0 if value.get('fail')==0 else 1)
    time.sleep(0.5)
raise SystemExit('原生测试未在60秒内写出同一次运行的结果；不把安装/启动算作测试通过。')
