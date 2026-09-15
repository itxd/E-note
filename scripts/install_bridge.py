#!/usr/bin/env python3
"""Install a per-user bridge runtime and optionally its launch agent. 作者：韦冬 2220285589@qq.com"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--enable',action='store_true',help='配置核验通过后启用登录自动启动')
args=p.parse_args()
root=Path(__file__).resolve().parents[1]
support=Path.home()/'Library/Application Support/ENote'
runtime=support/'bridge-runtime'; runtime.mkdir(parents=True,exist_ok=True,mode=0o700)
config=support/'bridge.json'
if not config.exists():
    shutil.copyfile(root/'bridge/config.example.json',config); os.chmod(config,0o600)
shutil.copyfile(root/'bridge/enote_bridge.py',runtime/'enote_bridge.py')
shutil.copyfile(root/'bridge/kimi-discussion.md',runtime/'kimi-discussion.md')
shutil.copyfile(root/'bridge/requirements.txt',runtime/'requirements.txt')
venv=runtime/'venv'
if not (venv/'bin/python3').exists(): subprocess.run([sys.executable,'-m','venv',str(venv)],check=True)
python=venv/'bin/python3'
subprocess.run([str(python),'-m','pip','install','-r',str(runtime/'requirements.txt')],check=True)
print('配置文件：'+str(config))
print('填写飞书应用、允许用户、账号与工作目录后，可加 --enable 安装登录启动。')
if args.enable:
    subprocess.run([str(python),str(runtime/'enote_bridge.py'),'--config',str(config),'--check'],check=True)
    import json
    c=json.loads(config.read_text())
    if not c.get('appID') or not c.get('appSecret'): raise SystemExit('先填写飞书 appID / appSecret')
    agents=Path.home()/'Library/LaunchAgents'; agents.mkdir(exist_ok=True)
    plist=agents/'com.weidong.enote.bridge.plist'
    value=dict(Label='com.weidong.enote.bridge',ProgramArguments=[str(python),str(runtime/'enote_bridge.py'),'--config',str(config)],
               RunAtLoad=True,KeepAlive=True,ThrottleInterval=15,WorkingDirectory=str(runtime),
               StandardOutPath=str(runtime/'stdout.log'),StandardErrorPath=str(runtime/'stderr.log'),
               EnvironmentVariables=dict(PATH=os.environ.get('PATH','/usr/local/bin:/usr/bin:/bin')),Umask=0o077)
    plist.write_bytes(plistlib.dumps(value)); os.chmod(plist,0o600)
    subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(plist)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
    print('E note 飞书桥接已启用；请保持桌面应用运行并登录。')
