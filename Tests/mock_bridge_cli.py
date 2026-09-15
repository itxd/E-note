#!/usr/bin/env python3
"""Deterministic CLI test double. Actual runner invokes this as a child process."""
import json
import sys
from pathlib import Path
args=sys.argv[1:]
prompt=sys.stdin.read()
output=Path(args[args.index('-o')+1])
if args[args.index('--sandbox')+1]=='read-only':
    ready='CONFIRMED_SCOPE' in prompt
    result=json.dumps(dict(reply='请确认目标文件、工作目录和验收标准。' if not ready else '目标和验收已经明确，请核对实施方案。',
                           ready=ready,plan='Create completed.txt containing verified; check its contents. Do not publish.' if ready else ''),ensure_ascii=False)
else:
    Path('completed.txt').write_text('verified')
    assert Path('completed.txt').read_text()=='verified'
    print(json.dumps(dict(type='item.completed',item=dict(type='command_execution',command='verify completed.txt',exit_code=0))))
    result='Created completed.txt; content verified; all checks passed.'
output.write_text(result)
