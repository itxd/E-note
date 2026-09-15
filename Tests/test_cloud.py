#!/usr/bin/env python3
"""Real SQLite transactions: independent devices, stale writes, duplicate delivery and execution gates."""
import concurrent.futures
import importlib.util
import pathlib
import tempfile
import unittest
import uuid
import time
import subprocess

spec = importlib.util.spec_from_file_location('enote_server', pathlib.Path(__file__).parents[1]/'server/enote_server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def uid(): return str(uuid.uuid4()).upper()


class CloudTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.cloud = server.Cloud(self.temp.name, 'test-invite')
        self.a = self.cloud.handle('POST','/v1/auth/register',dict(username='alice',password='long-test-password',deviceID='A',registrationCode='test-invite'))['token']
        self.b = self.cloud.handle('POST','/v1/auth/login',dict(username='alice',password='long-test-password',deviceID='B'))['token']
        self.c = self.cloud.handle('POST','/v1/auth/register',dict(username='bob',password='long-test-password',deviceID='C',registrationCode='test-invite'))['token']

    def tearDown(self): self.temp.cleanup()

    def call(self, path, data=None, token=None, rid=None):
        data = dict(data or {})
        if rid is None: rid = uid()
        data['requestID'] = rid
        return self.cloud.handle('POST',path,data,token or self.a)

    def snapshot(self, token=None): return self.cloud.handle('GET','/v1/sync',{},token or self.a)

    def todo(self, text='Write a design'):
        return dict(id=uid(),kind='todo',baseRevision=0,deleted=False,
                    payload=dict(text=text,category='work',priority='normal',completed=False,dueAt=None))

    def flow(self):
        t=self.todo(); snap=self.call('/v1/sync',dict(changes=[t]))
        f=self.call('/v1/workflows',dict(cursor=snap['cursor'],todoID=t['id']))['workflow']
        return t,f

    def action(self,f,action,**extra):
        return self.call('/v1/workflows/'+f['id']+'/'+action,dict(cursor=self.snapshot()['cursor'],**extra))['workflow']

    def approved(self):
        t,f=self.flow()
        f=self.action(f,'message',role='user',text='Build in /tmp/demo and run tests; do not publish')
        f=self.action(f,'plan',plan='1. Add greeting file. 2. Verify content. 3. Report result.',workspace='/tmp/demo')
        f=self.action(f,'approve',planVersion=f['planVersion'],approvalCode=f['approvalCode'],actor='user-open-id')
        return t,f

    def test_tags_and_archive_round_trip(self):
        tag = dict(id=uid(), kind='tag', baseRevision=0, deleted=False,
                   payload=dict(name='v2', type='版本', details='Release scope', link='https://example.com'))
        todo = self.todo()
        todo['payload'].update(tagIDs=[tag['id']], completed=True, completedAt=1000, archivedAt=260200)
        self.call('/v1/sync', dict(changes=[tag, todo]))
        entities = {e['id']: e for e in self.snapshot(self.b)['entities']}
        self.assertEqual(entities[tag['id']]['payload'], tag['payload'])
        self.assertEqual(entities[todo['id']]['payload']['tagIDs'], [tag['id']])
        self.assertEqual(entities[todo['id']]['payload']['archivedAt'], 260200)
        self.assertEqual(self.snapshot(self.c)['entities'], [])
        invalid = self.todo(); invalid['payload']['tagIDs'] = ['bad-id']
        with self.assertRaises(server.Fault):
            self.call('/v1/sync', dict(changes=[invalid]))

    def test_account_isolation_atomic_cas_and_no_reused_numbers(self):
        a,b=self.todo('first'),self.todo('second')
        snap=self.call('/v1/sync',dict(changes=[a,b])); self.assertEqual(snap['cursor'],2)
        self.assertEqual(self.snapshot(self.c)['entities'],[])
        records={e['id']:e for e in snap['entities']}
        a['baseRevision']=records[a['id']]['revision']; a['payload']['text']='updated'
        self.call('/v1/sync',dict(changes=[a]),token=self.b)
        b['baseRevision']=records[b['id']]['revision']; b['payload']['text']='must not be partially saved'
        with self.assertRaises(server.Fault) as e: self.call('/v1/sync',dict(changes=[b,a]))
        self.assertEqual(e.exception.status,409)
        saved={e['id']:e for e in self.snapshot()['entities']}
        self.assertEqual(saved[b['id']]['payload']['text'],'second')
        b['deleted']=True; self.call('/v1/sync',dict(changes=[b]))
        fresh=self.todo('third'); snap=self.call('/v1/sync',dict(changes=[fresh]))
        self.assertEqual(next(e for e in snap['entities'] if e['id']==fresh['id'])['payload']['number'],3)
        # Restart using the real encrypted database.
        restarted=server.Cloud(self.temp.name,'test-invite')
        self.assertEqual(restarted.handle('GET','/v1/sync',{},self.a)['cursor'],self.snapshot()['cursor'])
        data=(pathlib.Path(self.temp.name)/'cloud.sqlite3').read_bytes()
        self.assertNotIn(b'must not be partially saved',data)
        self.assertNotIn(b'long-test-password',data)
        self.assertNotIn(b'Write a design',data)

    def test_consistent_encrypted_backup_restores(self):
        self.call('/v1/sync',dict(changes=[self.todo('backup round trip')]))
        destination=pathlib.Path(self.temp.name)/'backup'
        subprocess.run(['python3',str(pathlib.Path(__file__).parents[1]/'server/backup.py'),'--data',self.temp.name,'--output',str(destination)],check=True,stdout=subprocess.DEVNULL)
        restored=server.Cloud(destination,'test-invite')
        actual=restored.handle('GET','/v1/sync',{},self.a)
        self.assertEqual(actual['entities'],self.snapshot()['entities'])
        self.assertEqual((destination/'master.key').stat().st_mode & 0o777,0o600)

    def test_request_idempotency_and_parallel_creates(self):
        t=self.todo(); rid=uid()
        one=self.call('/v1/sync',dict(changes=[t]),rid=rid)
        replay=self.call('/v1/sync',dict(changes=[t]),rid=rid)
        self.assertEqual(one['entities'],replay['entities']); self.assertEqual(one['cursor'],replay['cursor'])
        with self.assertRaises(server.Fault): self.call('/v1/sync',dict(changes=[]),rid=rid)
        def create(i): return self.call('/v1/sync',dict(changes=[self.todo(str(i))]))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(create,range(16)))
        numbers=[e['payload']['number'] for e in self.snapshot()['entities']]
        self.assertEqual(len(numbers),17); self.assertEqual(len(set(numbers)),17)

    def test_human_gate_single_claim_lease_and_accept(self):
        t,f=self.flow()
        with self.assertRaises(server.Fault): self.action(f,'claim')
        with self.assertRaises(server.Fault): self.action(f,'plan',plan='skip discussion',workspace='/tmp/demo')
        f=self.action(f,'message',role='user',text='Create file and test')
        f=self.action(f,'plan',plan='Create file, test, report',workspace='/tmp/demo')
        with self.assertRaises(server.Fault): self.action(f,'approve',planVersion=1,approvalCode='wrong',actor='human')
        f=self.action(f,'approve',planVersion=1,approvalCode=f['approvalCode'],actor='human')
        cursor=self.snapshot()['cursor']
        def claim(token):
            try: return self.call('/v1/workflows/'+f['id']+'/claim',dict(cursor=cursor),token=token)['workflow']
            except server.Fault: return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(claim,[self.a,self.b]))
        winners=[r for r in results if r]; self.assertEqual(len(winners),1)
        f=winners[0]; token=self.a if f['deviceID']=='A' else self.b
        with self.assertRaises(server.Fault): self.call('/v1/workflows/'+f['id']+'/finish',dict(leaseToken='bad',success=True,result='done'),token=token)
        self.call('/v1/workflows/'+f['id']+'/event',dict(leaseToken=f['leaseToken'],text='test command passed'),token=token)
        self.call('/v1/workflows/'+f['id']+'/finish',dict(leaseToken=f['leaseToken'],success=True,result='file created; tests passed'),token=token)
        self.assertFalse(next(e for e in self.snapshot()['entities'] if e['id']==t['id'])['payload']['completed'])
        f=self.action(f,'accept',accepted=True)
        self.assertEqual(f['state'],'completed')
        snap=self.snapshot(); todo=next(e for e in snap['entities'] if e['id']==t['id'])
        note=next(e for e in snap['entities'] if e['id']==f['noteID'])
        self.assertTrue(todo['payload']['completed']); self.assertEqual(note['payload']['linkedTodoID'],t['id'])
        self.assertIn('test command passed',note['payload']['body']); self.assertIn('tests passed',note['payload']['body'])

    def test_expired_owner_can_record_result_but_cannot_resume_work(self):
        _,f=self.approved(); f=self.action(f,'claim')
        with self.cloud.transaction() as db:
            account,_=self.cloud.auth(db,self.a); f['leaseUntil']=time.time()-1
            self.cloud.save_flow(db,account,f)
        with self.assertRaises(server.Fault): self.action(f,'heartbeat',leaseToken=f['leaseToken'])
        f=self.action(f,'finish',leaseToken=f['leaseToken'],success=False,result='Stopped after lost network; result preserved')
        self.assertEqual(f['state'],'failed')

    def test_stale_approval_expired_lease_never_auto_reassigned(self):
        t,f=self.approved()
        snap=self.snapshot(); todo=next(e for e in snap['entities'] if e['id']==t['id'])
        todo['baseRevision']=todo['revision']; todo['payload']['text']='scope changed'
        self.call('/v1/sync',dict(changes=[todo]))
        with self.assertRaises(server.Fault): self.action(f,'claim')
        t,f=self.approved(); f=self.action(f,'claim')
        with self.cloud.transaction() as db:
            account,_=self.cloud.auth(db,self.a); f['leaseUntil']=time.time()-1
            self.cloud.save_flow(db,account,f)
        with self.assertRaises(server.Fault): self.action(f,'claim')
        with self.assertRaises(server.Fault): self.action(f,'heartbeat',leaseToken=f['leaseToken'])
        with self.assertRaises(server.Fault): self.action(f,'recover',confirmedStopped=False)
        f=self.action(f,'recover',confirmedStopped=True)
        self.assertEqual(f['state'],'interrupted')
        with self.assertRaises(server.Fault): self.action(f,'claim')


if __name__=='__main__': unittest.main(verbosity=2)
