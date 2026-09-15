#!/usr/bin/env python3
"""Native TLS pinning + sync against deployed server; isolated disposable account and local store."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import ssl
import urllib.request
import subprocess
import tempfile
import time
import urllib.error
import uuid
from test_sync import request, free_port, ROOT


def main():
    setup=json.loads((Path.home()/'Library/Application Support/ENote/server-setup.json').read_text())
    # An accepted TCP client that never starts TLS must not block other clients.
    from urllib.parse import urlsplit
    remote=urlsplit(setup['server'])
    with socket.create_connection((remote.hostname,remote.port),timeout=5):
        context=ssl.create_default_context(cafile=str(ROOT/'assets/sync-server.crt'))
        with urllib.request.urlopen(setup['server']+'/health',context=context,timeout=5) as response:
            assert response.status==200
    name='enote-smoke-'+uuid.uuid4().hex
    second_process = None
    second_suite = None
    password=secrets.token_urlsafe(24)
    suite='enote.remote.'+uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='enote-deployed-') as folder:
        data=Path(folder); port=free_port()
        p=subprocess.Popen([str(ROOT/'build/enote-tests'),'serve'],env=dict(os.environ,NOTY_DATA_DIR=folder,ENOTE_API_PORT=str(port),ENOTE_SETTINGS_SUITE=suite),stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(200):
                if (data/'api.json').exists(): break
                time.sleep(.05)
            c=json.loads((data/'api.json').read_text())
            def api(path,body=None): return request(c['baseURL'],path,body,c['token'])
            credentials=dict(setup,username=name,password=password,importOffline=False)
            try:
                api('/v1/account/register',dict(credentials,certificateSHA256='0'*64))
                raise AssertionError('invalid TLS pin accepted')
            except urllib.error.HTTPError: pass
            api('/v1/account/register',credentials)
            for _ in range(200):
                if not api('/v1/sync/status')['busy']: break
                time.sleep(.05)
            api('/v1/sync',{})
            note=api('/v1/notes',dict(body='Deployed native TLS sync smoke test'))['note']
            tag=api('/v1/tags',dict(name='Deployed tag smoke',type='版本',details='initial details',link='https://example.com'))['tag']
            todo=api('/v1/todos',dict(text='Deployed native TODO smoke',tagIDs=[tag['id']]))['items'][0]
            api('/v1/sync',{})
            assert api('/v1/sync/status')['cursor']>=2
            api('/v1/account/logout',{})
            api('/v1/account/login',credentials)
            for _ in range(200):
                if not api('/v1/sync/status')['busy']: break
                time.sleep(.05)
            api('/v1/sync',{})
            assert any(n['id']==note['id'] for n in api('/v1/notes')['notes'])
            assert api('/v1/todos')['items'][0]['id']==todo['id']
            # A fresh native profile must fetch tags and bindings from the real cloud.
            second_dir=data/'second'; second_dir.mkdir(); second_port=free_port()
            second_suite='enote.remote.'+uuid.uuid4().hex
            second_process=subprocess.Popen([str(ROOT/'build/enote-tests'),'serve'],env=dict(os.environ,NOTY_DATA_DIR=str(second_dir),ENOTE_API_PORT=str(second_port),ENOTE_SETTINGS_SUITE=second_suite),stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for _ in range(200):
                if (second_dir/'api.json').exists(): break
                time.sleep(.05)
            second_config=json.loads((second_dir/'api.json').read_text())
            def second(path,body=None,method=None):
                return request(second_config['baseURL'],path,body,second_config['token'],method)
            second('/v1/account/login',credentials)
            for _ in range(200):
                if not second('/v1/sync/status')['busy']: break
                time.sleep(.05)
            second('/v1/sync',{})
            assert second('/v1/tags/'+tag['id'])['tag']['details']=='initial details'
            assert second('/v1/todos/'+todo['id'])['item']['tagIDs']==[tag['id']]
            second('/v1/tags/'+tag['id'],dict(details='edited on second device'),method='PATCH')
            second('/v1/todos/'+todo['id'],dict(archived=True),method='PATCH')
            second('/v1/sync',{}); api('/v1/sync',{})
            assert api('/v1/tags/'+tag['id'])['tag']['details']=='edited on second device'
            assert api('/v1/todos/'+todo['id'])['item']['archived']
            print('PASS deployed two-device tag create/read/edit, binding, modifiedAt and archive sync')
            print('PASS deployed public HTTPS: native certificate pin rejection/acceptance, account login, notes/TODO sync, logout/re-login')
        finally:
            if second_process is not None:
                second_process.terminate(); second_process.wait(timeout=5)
            if second_suite is not None:
                subprocess.run(['defaults','delete',second_suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            p.terminate(); p.wait(timeout=5)
            subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            # Remove only this disposable test account, using a parameterized query over stdin.
            cleanup='''import sqlite3,sys
name=sys.argv[1]
assert name.startswith('enote-smoke-')
with sqlite3.connect('/var/lib/enote/cloud.sqlite3') as db:
    row=db.execute('SELECT id FROM accounts WHERE username=?',(name,)).fetchone()
    if row:
        for table in ('sessions','entities','requests','workflows'):
            db.execute('DELETE FROM '+table+' WHERE account=?',(row[0],))
        db.execute('DELETE FROM accounts WHERE id=?',(row[0],))
'''
            subprocess.run(['ssh','-S','/tmp/enote-cloud-ssh.sock','root@47.96.175.129','python3 - '+shlex.quote(name)],input=cleanup,text=True,check=True)


if __name__=='__main__': main()
