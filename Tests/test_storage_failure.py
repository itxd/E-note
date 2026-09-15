#!/usr/bin/env python3
"""Never rewrite unreadable encrypted user data during startup or an API mutation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import uuid
from test_sync import ROOT,free_port,request


def main():
    for case in ('json','key','ciphertext'):
        with tempfile.TemporaryDirectory(prefix='enote-corrupt-') as temp:
            data=Path(temp); suite='enote.corrupt.'+uuid.uuid4().hex; port=free_port()
            record=dict(id=str(uuid.uuid4()),title='Protected original',colorName='雾紫',createdAt='2026-09-14T00:00:00Z',modifiedAt='2026-09-14T00:00:00Z',isPinned=False,isArchived=False,body='INVALID_CIPHERTEXT')
            original=b'broken json' if case=='json' else (b'[]' if case=='key' else json.dumps([record]).encode())
            key=b'invalid key' if case=='key' else os.urandom(32)
            (data/'notes.json').write_bytes(original); (data/'note.key').write_bytes(key)
            p=subprocess.Popen([str(ROOT/'build/enote-tests'),'serve'],env=dict(os.environ,NOTY_DATA_DIR=temp,ENOTE_API_PORT=str(port),ENOTE_SETTINGS_SUITE=suite),stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                for _ in range(200):
                    if (data/'api.json').exists(): break
                    time.sleep(.05)
                config=json.loads((data/'api.json').read_text())
                try:
                    request(config['baseURL'],'/v1/notes',dict(body='must not overwrite damaged data'),config['token'])
                    raise AssertionError('write unexpectedly succeeded')
                except urllib.error.HTTPError as e: assert e.code==500
                assert (data/'notes.json').read_bytes()==original
                assert (data/'note.key').read_bytes()==key
            finally:
                p.terminate(); p.wait(timeout=5)
                subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print('PASS unreadable JSON, key and ciphertext remain byte-for-byte unchanged after startup and attempted writes')


if __name__=='__main__': main()
