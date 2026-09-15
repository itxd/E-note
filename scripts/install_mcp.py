#!/usr/bin/env python3
"""Install the local E note MCP connector and print a client configuration."""
import argparse
import json
from pathlib import Path
import shutil
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dest', type=Path, default=Path.home() / 'Library/Application Support/ENote/mcp')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / 'skills/e-note/scripts'
    destination = args.dest.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('e_note.py', 'e_note_mcp.py'):
        shutil.copy2(source / name, destination / name)
    shutil.copy2(root / 'LICENSE', destination / 'LICENSE')
    config = {'mcpServers': {'e-note': {'command': sys.executable,
              'args': [str(destination / 'e_note_mcp.py')]}}}
    rendered = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    (destination / 'mcp-config.json').write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
