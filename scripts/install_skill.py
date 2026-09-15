#!/usr/bin/env python3
"""安装项目内的 e-note skill。作者：韦冬 2220285589@qq.com"""
import os
from pathlib import Path

source = Path(__file__).resolve().parents[1] / 'skills' / 'e-note'
base = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
target = base / 'skills' / 'e-note'
target.parent.mkdir(parents=True, exist_ok=True)
if target.exists() or target.is_symlink():
    if target.resolve() != source:
        raise SystemExit('已有其他同名 skill，未覆盖：' + str(target))
else:
    target.symlink_to(source, target_is_directory=True)
print('e-note skill 已就绪：' + str(target))
