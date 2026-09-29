"""Completion cannot precede a verified conclusion in the correct note."""
import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'skills/e-note/scripts'))
import e_note_mcp as mcp

TODO = '60070B6B-BFAC-4443-8843-989739EF7629'
NOTE = 'FC522C23-5E6C-5110-1100-4F9444E62AE9'


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.todo = {'id': TODO, 'code': 'T000027', 'completed': False}
        self.note = {'id': NOTE, 'kind': 'note', 'linkedTodoID': TODO,
                     'deletedAt': None, 'workflowID': None, 'body': '原需求\n保留历史\n'}
        self.calls = []
        self.fail_save = self.mismatch = self.fail_close = False
        self.args = {'id': 'T000027', 'completed': True, 'completionNoteID': NOTE,
                     'executionConclusion': '实现完成；53 项验证通过；交付 docs；无剩余事项。'}

    def request(self, config, method, path, payload=None):
        self.calls.append((method, path, payload))
        if method == 'GET' and path.startswith('/v1/todos/'):
            return {'item': copy.deepcopy(self.todo)}
        if method == 'GET' and path == '/v1/notes/' + NOTE:
            note = copy.deepcopy(self.note)
            if self.mismatch and any(c[0] == 'PATCH' for c in self.calls):
                note['body'] = '其他设备新内容'
            return {'note': note}
        if method == 'PATCH' and path == '/v1/notes/' + NOTE:
            if self.fail_save:
                raise OSError('storage unavailable')
            self.note.update(payload)
            return {'note': copy.deepcopy(self.note)}
        if method == 'PATCH' and path == '/v1/todos/' + TODO:
            if self.fail_close:
                raise OSError('timeout')
            self.todo.update(payload)
            return {'item': copy.deepcopy(self.todo)}
        raise AssertionError((method, path))

    def invoke(self, args=None):
        with patch.object(mcp, 'api_request', self.request):
            return mcp.invoke('enote_update_todo', self.args if args is None else args, None)

    def test_missing_conclusion_never_closes(self):
        for field in ['completionNoteID', 'executionConclusion']:
            args = dict(self.args)
            del args[field]
            with self.assertRaises(mcp.CompletionError):
                self.invoke(args)
        self.assertEqual(self.calls, [])

    def test_wrong_deleted_or_workflow_note_never_writes(self):
        for changes in [{'linkedTodoID': NOTE}, {'deletedAt': '2026-09-29'}, {'workflowID': TODO}]:
            original = dict(self.note)
            self.note.update(changes)
            with self.assertRaises(mcp.CompletionError):
                self.invoke()
            self.note = original
        self.assertTrue(all(call[0] == 'GET' for call in self.calls))

    def test_success_preserves_history_and_reads_back_before_closing(self):
        old = self.note['body']
        self.assertTrue(self.invoke()['item']['completed'])
        self.assertTrue(self.note['body'].startswith(old))
        self.assertIn(self.args['executionConclusion'], self.note['body'])
        self.assertEqual([c[0] for c in self.calls], ['GET', 'GET', 'PATCH', 'GET', 'PATCH'])
        self.assertEqual(self.calls[-1], ('PATCH', '/v1/todos/' + TODO, {'completed': True}))

    def test_save_failure_and_readback_mismatch_never_close(self):
        self.fail_save = True
        with self.assertRaises(OSError):
            self.invoke()
        self.fail_save, self.mismatch = False, True
        with self.assertRaises(mcp.CompletionError):
            self.invoke()
        self.assertFalse(self.todo['completed'])
        self.assertFalse(any(c[0] == 'PATCH' and '/todos/' in c[1] for c in self.calls))

    def test_retry_after_close_failure_does_not_duplicate_note(self):
        self.fail_close = True
        with self.assertRaises(OSError):
            self.invoke()
        body = self.note['body']
        self.fail_close = False
        self.invoke()
        self.invoke()
        self.assertEqual(self.note['body'], body)
        self.assertEqual(sum(c[0] == 'PATCH' and '/notes/' in c[1] for c in self.calls), 1)

    def test_completion_fields_cannot_silently_accompany_other_updates(self):
        with self.assertRaises(mcp.CompletionError):
            self.invoke(dict(self.args, completed=False))
        self.assertEqual(self.calls, [])

    def test_dispatch_explains_missing_conclusion(self):
        response = mcp.dispatch({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                 'params': {'name': 'enote_update_todo',
                                            'arguments': {'id': 'T000027', 'completed': True}}}, None)
        self.assertTrue(response['result']['isError'])
        self.assertIn('executionConclusion', response['result']['content'][0]['text'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
