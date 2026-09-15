#!/usr/bin/env python3
"""Create a consistent encrypted database + key backup, without exposing plaintext. 作者：韦冬 2220285589@qq.com"""
import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--data',default='/var/lib/enote')
p.add_argument('--output',required=True)
args=p.parse_args()
source=Path(args.data); target=Path(args.output)
if target.exists(): raise SystemExit('Backup target already exists; refusing to overwrite')
target.mkdir(parents=True,mode=0o700)
os.umask(0o077)
try:
    with sqlite3.connect(source/'cloud.sqlite3') as original, sqlite3.connect(target/'cloud.sqlite3') as copy:
        original.backup(copy)
        if copy.execute('PRAGMA integrity_check').fetchone()[0]!='ok': raise RuntimeError('Backup integrity check failed')
    shutil.copyfile(source/'master.key',target/'master.key')
    os.chmod(target/'cloud.sqlite3',0o600); os.chmod(target/'master.key',0o600)
except BaseException:
    shutil.rmtree(target)
    raise
print('Consistent encrypted backup created:',target)
