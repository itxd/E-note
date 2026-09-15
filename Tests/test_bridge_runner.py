#!/usr/bin/env python3
"""Real process lifecycle tests; no Feishu application or AI subscription needed."""
import importlib.util
import os
from pathlib import Path
import tempfile
import sqlite3
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('enote_bridge',ROOT/'bridge/enote_bridge.py')
bridge=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='enote-watchdog-')
        self.root=Path(self.temp.name)
        self.command=self.root/'cli.py'
        self.command.write_text('''#!/usr/bin/env python3
import os,signal,sys,time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path('pid').write_text(str(os.getpid()))
mode=sys.stdin.read()
if mode=='success':
    time.sleep(.4)
    Path(sys.argv[sys.argv.index('-o')+1]).write_text('verified')
else:
    while True:
        Path('alive').write_text(str(time.monotonic()))
        time.sleep(.02)
''')
        self.command.chmod(0o700)
        self.runner=bridge.AIRunner(dict(provider='codex',command=str(self.command),workspaces=[str(self.root)],executionTimeoutSeconds=4),bridge.Journal(self.root/'journal'))
        self.runner.heartbeat_interval=.04
        self.runner.lease_silence_limit=.25
        self.runner.termination_grace=.1
        self.runner.monitor_interval=.01

    def tearDown(self): self.temp.cleanup()

    def assert_stopped(self):
        pid=int((self.root/'pid').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid,0)
        last=(self.root/'alive').read_text() if (self.root/'alive').exists() else None
        time.sleep(.05)
        self.assertEqual(last,(self.root/'alive').read_text() if (self.root/'alive').exists() else None)

    def test_hung_renewal_stops_sigterm_resistant_cli_before_request_returns(self):
        release=threading.Event(); entered=threading.Event()
        def heartbeat(): entered.set(); release.wait(3)
        started=time.monotonic()
        try:
            with self.assertRaisesRegex(bridge.BridgeError,'续期失败'):
                self.runner.run('hang',self.root,'execution','hung-renewal',heartbeat)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic()-started,1.5)
            self.assert_stopped()
        finally: release.set()

    def test_failed_renewal_stops_process(self):
        # Test termination of a running child, independently of Python startup
        # speed. The watchdog timeout itself is covered by the hung-renewal test.
        self.runner.lease_silence_limit=2
        def heartbeat():
            deadline=time.monotonic()+1
            while not (self.root/'pid').exists() and time.monotonic()<deadline:
                time.sleep(.01)
            raise bridge.BridgeError('owner changed')
        with self.assertRaisesRegex(bridge.BridgeError,'owner changed'):
            self.runner.run('hang',self.root,'execution','rejected-renewal',heartbeat)
        self.assert_stopped()

    def test_late_initial_acknowledgement_cannot_start_cli(self):
        with self.assertRaisesRegex(bridge.BridgeError,'未启动 CLI'):
            self.runner.run('hang',self.root,'execution','stale-initial',lambda:None,lease_confirmed_at=time.monotonic()-1)
        self.assertFalse((self.root/'pid').exists())

    def test_successful_renewals_keep_execution_alive(self):
        calls=[]
        result,log=self.runner.run('success',self.root,'execution','normal',lambda:calls.append(time.monotonic()))
        self.assertEqual(result,'verified'); self.assertGreater(len(calls),2)
        self.assertEqual(log.stat().st_mode & 0o777,0o600)
        self.assert_stopped()


class JournalTests(unittest.TestCase):
    def test_failed_notification_write_does_not_mark_execution_finished(self):
        with tempfile.TemporaryDirectory(prefix='enote-outbox-') as temp:
            journal=bridge.Journal(temp)
            with journal.db() as db:
                db.execute('INSERT INTO executions VALUES(?,?,?,?,?)',('execution','{}','chat','recording','result'))
                db.execute("CREATE TRIGGER fail_notification BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END")
            with self.assertRaises(sqlite3.IntegrityError): journal.finish_execution('execution','chat','x'*8000)
            with journal.db() as db:
                self.assertEqual(db.execute('SELECT state FROM executions').fetchone()[0],'recording')
                self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0],0)
                db.execute('DROP TRIGGER fail_notification')
            journal.finish_execution('execution','chat','x'*8000)
            journal.finish_execution('execution','chat','x'*8000)
            with journal.db() as db:
                self.assertEqual(db.execute('SELECT state FROM executions').fetchone()[0],'finished')
                self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0],3)



if __name__=='__main__': unittest.main(verbosity=2)
