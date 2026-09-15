#!/usr/bin/env python3
"""Two separate native desktop stores against an actual HTTP cloud, no real user data."""
import json
import importlib.util
import base64
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import uuid

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]


def request(base, path, body=None, token=None, method=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path, data=json.dumps(body).encode() if body is not None else None,
                               headers=headers,method=method or ('POST' if body is not None else 'GET'))
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=120) as r:
        return json.load(r)


def main():
    processes=[]; suites=[]
    with tempfile.TemporaryDirectory(prefix='enote-sync-') as temp:
        temp=Path(temp)
        cloud_port=free_port(); cloud_url=f'http://127.0.0.1:{cloud_port}'
        env=dict(os.environ,ENOTE_REGISTRATION_CODE='integration-invite')
        cloud=subprocess.Popen(['python3',str(ROOT/'server/enote_server.py'),'--data',str(temp/'cloud'),'--port',str(cloud_port)],env=env,stdout=subprocess.DEVNULL)
        processes.append(cloud)
        clients=[]
        try:
            for _ in range(100):
                try: request(cloud_url,'/health'); break
                except OSError: time.sleep(.05)
            for label in ('A','B'):
                data=temp/label; data.mkdir(); port=free_port(); suite='enote.sync.'+str(uuid.uuid4()); suites.append(suite)
                env=dict(os.environ,NOTY_DATA_DIR=str(data),ENOTE_API_PORT=str(port),ENOTE_SETTINGS_SUITE=suite)
                p=subprocess.Popen([str(ROOT/'build/enote-tests'),'serve'],env=env,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                processes.append(p)
                for _ in range(200):
                    if (data/'api.json').exists(): break
                    if p.poll() is not None: raise RuntimeError('Native test host exited')
                    time.sleep(.05)
                config=json.loads((data/'api.json').read_text()); clients.append(config)
            def api(index,path,body=None,method=None):
                c=clients[index]; return request(c['baseURL'],path,body,c['token'],method)
            def sync(index):
                for _ in range(100):
                    if not api(index,'/v1/sync/status')['busy']: break
                    time.sleep(.05)
                return api(index,'/v1/sync',{})
            # Offline note stays offline unless import is explicitly enabled.
            offline=api(0,'/v1/notes',dict(body='offline private note'))['note']
            login=dict(server=cloud_url,username='test-account',password='integration-password',importOffline=False)
            api(0,'/v1/account/register',dict(login,registrationCode='integration-invite'))
            sync(0)
            api(1,'/v1/account/login',login); sync(1)
            assert not any(n['id']==offline['id'] for n in api(0,'/v1/notes')['notes'])
            todo=api(0,'/v1/todos',dict(text='shared TODO',category='work'))['items'][0]
            note=api(0,'/v1/notes',dict(body='Shared ordinary note'))['note']
            sync(0); sync(1)
            assert api(1,'/v1/todos/'+todo['id'])['item']['text']=='shared TODO'
            assert next(n for n in api(1,'/v1/notes')['notes'] if n['id']==note['id'])['body']=='Shared ordinary note'
            # Tags are shared entities; bindings and archive state survive device sync.
            tag = api(0, '/v1/tags', dict(name='E note v2', type='版本', details='Release scope', link=''))['tag']
            api(0, '/v1/todos/'+todo['id'], dict(tagIDs=[tag['id']]), method='PATCH')
            sync(0); sync(1)
            assert api(1, '/v1/tags')['tags'][0]['details'] == 'Release scope'
            assert api(1, '/v1/tags/'+tag['id'])['tag']['modifiedAt'] == tag['modifiedAt']
            second_tag = api(1, '/v1/tags', dict(name='second'))['tag']
            assert api(1, '/v1/tags')['tags'][0]['id'] == second_tag['id']
            assert api(1, '/v1/todos/'+todo['id'])['item']['tagIDs'] == [tag['id']]
            api(1, '/v1/tags/'+tag['id'], dict(details='Updated on B'), method='PATCH')
            api(1, '/v1/todos/'+todo['id'], dict(archived=True), method='PATCH')
            sync(1); sync(0)
            assert api(0, '/v1/tags')['tags'][0]['details'] == 'Updated on B'
            assert api(0, '/v1/tags')['tags'][0]['id'] == tag['id']
            assert api(0, '/v1/todos/'+todo['id'])['item']['archived']
            api(0, '/v1/todos/'+todo['id'], dict(archived=False), method='PATCH')
            sync(0); sync(1)
            assert not api(1, '/v1/todos/'+todo['id'])['item']['archived']
            # Concurrent edits to distinct fields combine.
            api(0,'/v1/todos/'+todo['id'],dict(text='edited on A'),method='PATCH')
            api(1,'/v1/todos/'+todo['id'],dict(completed=True),method='PATCH')
            sync(0); sync(1); sync(0)
            merged=api(0,'/v1/todos/'+todo['id'])['item']
            assert merged['text']=='edited on A' and merged['completed']
            # Concurrent same-field edit is retained as a visible conflict, never silently overwritten.
            api(0,'/v1/todos/'+todo['id'],dict(text='A version'),method='PATCH')
            api(1,'/v1/todos/'+todo['id'],dict(text='B version'),method='PATCH')
            sync(0)
            try: sync(1); raise AssertionError('expected conflict')
            except urllib.error.HTTPError as e: assert e.code in (409,502)
            status=api(1,'/v1/sync/status'); assert len(status['conflicts'])==1
            assert api(1,'/v1/todos/'+todo['id'])['item']['text']=='B version'
            api(1,'/v1/sync/resolve',dict(id=todo['id'],choice='both')); sync(1); sync(0)
            texts={t['text'] for t in api(0,'/v1/todos')['items']}; assert {'A version','B version'}<=texts
            # Returning to standalone restores its original data. Re-login keeps cloud records.
            api(0,'/v1/account/logout',{})
            assert api(0,'/v1/sync/status')['signedIn'] is False
            assert next(n for n in api(0,'/v1/notes')['notes'] if n['id']==offline['id'])['body']=='offline private note'
            assert not any(n['id']==note['id'] for n in api(0,'/v1/notes')['notes'])
            api(0,'/v1/account/login',login); sync(0)
            assert any(n['id']==note['id'] for n in api(0,'/v1/notes')['notes'])
            # A disconnected account remains editable; restarting cloud drains pending local writes.
            cloud.terminate(); cloud.wait(timeout=5)
            api(0,'/v1/todos',dict(text='offline pending write'))
            try: sync(0); raise AssertionError('network should fail')
            except urllib.error.HTTPError: pass
            cloud=subprocess.Popen(['python3',str(ROOT/'server/enote_server.py'),'--data',str(temp/'cloud'),'--port',str(cloud_port)],env=dict(os.environ,ENOTE_REGISTRATION_CODE='integration-invite'),stdout=subprocess.DEVNULL)
            processes.append(cloud)
            for _ in range(100):
                try: request(cloud_url,'/health'); break
                except OSError: time.sleep(.05)
            sync(0); sync(1)
            assert any(t['text']=='offline pending write' for t in api(1,'/v1/todos')['items'])
            # Real bridge command parser and child-process lifecycle against the native API/cloud.
            spec=importlib.util.spec_from_file_location('enote_bridge',ROOT/'bridge/enote_bridge.py')
            module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            workspace=temp/'work'; workspace.mkdir()
            config=dict(allowedUsers=['owner'],accountID=api(0,'/v1/sync/status')['accountID'],workspaces=[str(workspace)],
                        apiConfig=str(temp/'A/api.json'),dataDirectory=str(temp/'bridge'),provider='codex',
                        command=str(ROOT/'Tests/mock_bridge_cli.py'))
            bridge=module.Bridge(config)
            target=api(0,'/v1/todos',dict(text='Bridge integration task'))['items'][0]; sync(0)
            bridge.handle('msg-ignore','stranger','chat','讨论 '+target['id']+' do something')
            assert not bridge.flows()
            bridge.handle('msg-discuss','owner','chat','讨论 '+target['id']+' clarify first')
            flow=bridge.flows()[0]
            assert flow['state']=='discussing' and not (workspace/'completed.txt').exists()
            bridge.handle('msg-plan','owner','chat','继续 '+flow['id']+' CONFIRMED_SCOPE: create completed.txt and verify its contents')
            flow=bridge.flows()[0]
            assert flow['state']=='awaiting_approval' and not (workspace/'completed.txt').exists()
            try:
                bridge.handle('msg-invalid','owner','chat','确认执行 '+flow['id']+' 1 wrong-code')
                raise AssertionError('wrong confirmation accepted')
            except module.BridgeError: pass
            assert not (workspace/'completed.txt').exists()
            original_call=bridge.api.call
            fail_finish=[True]
            def transient_call(path,body=None,method=None):
                if path.endswith('/finish') and fail_finish[0]:
                    fail_finish[0]=False
                    raise module.BridgeError('simulated temporary network loss')
                return original_call(path,body,method)
            bridge.api.call=transient_call
            bridge.handle('msg-approve','owner','chat',f"确认执行 {flow['id']} {flow['planVersion']} {flow['approvalCode']}")
            bridge.executor.shutdown(wait=True)
            with bridge.journal.db() as db:
                assert db.execute("SELECT state FROM executions").fetchone()[0]=='recording'
            assert bridge.flush_results()
            assert (workspace/'completed.txt').read_text()=='verified'
            flow=bridge.flows()[0]; assert flow['state']=='awaiting_result',flow['state']
            assert not api(0,'/v1/todos/'+target['id'])['item']['completed']
            bridge.handle('msg-accept','owner','chat','验收 '+flow['id'])
            assert api(0,'/v1/todos/'+target['id'])['item']['completed']
            sync(1)
            linked=next(n for n in api(1,'/v1/notes')['notes'] if n['id']==flow['noteID'])
            assert linked['linkedTodoID']==target['id'] and 'all checks passed' in linked['body']
            with bridge.journal.db() as db:
                replies='\n'.join(r[0] for r in db.execute('SELECT text FROM outbox'))
                assert '确认执行' in replies and '验收' in replies
                assert db.execute('SELECT COUNT(*) FROM executions').fetchone()[0]==1
            print('PASS bridge workflow: allowlist, discussion before plan, explicit version/code approval, real CLI child, durable logs, cloud note links, result acceptance')
            # Simulate interruption after the durable sync journal was written but before notes/baseline commit.
            sync(0)
            processes[1].terminate(); processes[1].wait(timeout=5)
            profile=(temp/'A/active-profile').read_text()
            account_dir=temp/'A/accounts'/profile
            cipher=AESGCM((temp/'A/note.key').read_bytes())
            encoded=base64.b64decode((account_dir/'cloud-state.enc').read_bytes())
            state=json.loads(cipher.decrypt(encoded[:12],encoded[12:],None))
            entities=state['snapshot']['entities']
            next(e for e in entities if e['id']==note['id'])['payload']['body']='recovered atomic sync journal'
            nonce=os.urandom(12)
            journal={'state':json.loads(cipher.decrypt(encoded[:12],encoded[12:],None)), 'entities':entities}
            (account_dir/'sync-journal.enc').write_bytes(base64.b64encode(nonce+cipher.encrypt(nonce,json.dumps(journal).encode(),None)))
            from urllib.parse import urlsplit
            restarted=subprocess.Popen([str(ROOT/'build/enote-tests'),'serve'],env=dict(os.environ,NOTY_DATA_DIR=str(temp/'A'),
                                        ENOTE_API_PORT=str(urlsplit(clients[0]['baseURL']).port),ENOTE_SETTINGS_SUITE=suites[0],ENOTE_TEST_AUTO_SYNC='1'),
                                        stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            processes.append(restarted)
            for _ in range(200):
                try:
                    if not api(0,'/v1/sync/status')['busy']: break
                except OSError: pass
                time.sleep(.05)
            sync(0); sync(1)
            assert next(n for n in api(1,'/v1/notes')['notes'] if n['id']==note['id'])['body']=='recovered atomic sync journal'
            assert not (account_dir/'sync-journal.enc').exists()
            print('PASS interrupted atomic sync journal replays on native app startup and propagates to the second device')
            def skill(*arguments):
                result=subprocess.run(['python3',str(ROOT/'skills/e-note/scripts/e_note.py'),'--config',str(temp/'A/api.json'),*arguments],check=True,capture_output=True,text=True)
                return json.loads(result.stdout)
            assert skill('sync-status')['accountID']==config['accountID']
            cursor=skill('sync')['cursor']
            pending=next(t for t in api(0,'/v1/todos')['items'] if t['text']=='offline pending write')
            create_file=temp/'skill-flow.json'
            create_file.write_text(json.dumps(dict(requestID=str(uuid.uuid4()),cursor=cursor,todoID=pending['id'])))
            created=skill('workflow','--file',str(create_file))['workflow']
            assert created['todoID']==pending['id']
            assert any(f['id']==created['id'] for f in skill('workflows')['workflows'])
            print('PASS installed Skill client sync-status, sync, workflow create and workflows commands')
            for f in (temp/'A').rglob('*.enc'):
                assert b'shared TODO' not in f.read_bytes() and b'integration-password' not in f.read_bytes()
            subprocess.run([str(ROOT/'build/enote-tests'),'cloud-merge'],env=dict(os.environ,NOTY_DATA_DIR=str(temp/'merge'),ENOTE_SETTINGS_SUITE=suites[0]),check=True)
            print('PASS native two-device sync: account isolation, notes, TODO IDs, disjoint merge, conflicts, logout/login, offline replay')
        finally:
            for p in processes:
                if p.poll() is None: p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
            for suite in suites: subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__': main()
