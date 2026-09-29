#!/usr/bin/env python3
"""Exercise the E note MCP subprocess against an authenticated HTTP fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1]/'skills/e-note/scripts/e_note_mcp.py'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def handle_request(self):
        if self.headers.get('Authorization') != 'Bearer fixture-private-token':
            self.send_error(401)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.server.calls.append((self.command, self.path, json.loads(body) if body else None))
        if self.server.redirect:
            self.send_response(302)
            self.send_header('Location', '/credential-leak')
            self.end_headers()
            return
        result = {'items': [{'code': 'T000001', 'text': '中文任务', 'completed': False}]} if self.command == 'GET' else {'ok': True}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PATCH = handle_request


class MCPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.calls, self.server.redirect = [], False
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.config = Path(self.tmp.name)/'api.json'
        self.write_config('http://127.0.0.1:' + str(self.server.server_port))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()
        self.tmp.cleanup()

    def write_config(self, url):
        self.config.write_text(json.dumps({'baseURL': url, 'token': 'fixture-private-token'}))
        self.config.chmod(0o600)

    def run_messages(self, messages):
        result = subprocess.run([sys.executable, str(SCRIPT), '--config', str(self.config)],
                                input='\n'.join(json.dumps(m) for m in messages)+'\n',
                                capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(result.stderr, '')
        self.assertNotIn('fixture-private-token', result.stdout)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def call(self, name, arguments=None):
        return {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
                'params': {'name': name, 'arguments': arguments or {}}}

    def test_stdio_handshake_notification_and_authenticated_read(self):
        results = self.run_messages([
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
            self.call('enote_list_todos'),
        ])
        self.assertEqual(len(results), 3)
        self.assertEqual(results[0]['result']['protocolVersion'], '2025-06-18')
        spec = next(t for t in results[1]['result']['tools'] if t['name'] == 'enote_list_todos')
        self.assertTrue(spec['annotations']['readOnlyHint'])
        self.assertFalse(results[2]['result']['isError'])
        self.assertIn('中文任务', results[2]['result']['content'][0]['text'])
        self.assertEqual(self.server.calls, [('GET', '/v1/todos', None)])

    def test_create_and_update_preserve_unicode_and_fixed_id(self):
        results = self.run_messages([
            self.call('enote_create_note', {'title': '会议', 'body': '确认范围'}),
            self.call('enote_create_todo', {'text': '验证功能', 'priority': 'high'}),
            self.call('enote_update_todo', {'id': 't000001', 'completed': False, 'dueAt': None}),
        ])
        self.assertTrue(all(not r['result']['isError'] for r in results))
        self.assertEqual(self.server.calls[0], ('POST', '/v1/notes', {'title': '会议', 'body': '确认范围'}))
        self.assertEqual(self.server.calls[2], ('PATCH', '/v1/todos/T000001', {'completed': False, 'dueAt': None}))

    def test_tag_read_edit_and_todo_binding(self):
        identifier = '00000000-0000-0000-0000-000000000001'
        results = self.run_messages([
            self.call('enote_list_tags'),
            self.call('enote_create_tag', {'name': '版本', 'details': '目标'}),
            self.call('enote_get_tag', {'id': identifier}),
            self.call('enote_update_tag', {'id': identifier, 'details': '新目标'}),
            self.call('enote_update_todo', {'id': 'T000001', 'tagIDs': [identifier]}),
            self.call('enote_update_todo', {'id': 'T000001', 'tagIDs': [123]}),
            self.call('enote_get_tag', {'id': '../../account/logout'}),
        ])
        self.assertTrue(all(not r['result']['isError'] for r in results[:5]))
        self.assertTrue(all(r['result']['isError'] for r in results[5:]))
        self.assertEqual(len(self.server.calls), 5)
        self.assertEqual(self.server.calls[2], ('GET', '/v1/tags/' + identifier, None))
        self.assertEqual(self.server.calls[3], ('PATCH', '/v1/tags/' + identifier, {'details': '新目标'}))
        self.assertEqual(self.server.calls[4][2]['tagIDs'], [identifier])

    def test_invalid_input_never_reaches_http(self):
        results = self.run_messages([
            self.call('enote_update_todo', {'id': '../../account/logout', 'completed': True}),
            self.call('enote_update_todo', {'id': 'T000001'}),
            self.call('enote_update_todo', {'id': 'T000001', 'completed': 'true'}),
            self.call('enote_create_todo', {'text': '', 'priority': 'high'}),
            self.call('enote_list_todos', {'url': 'https://example.com'}),
            self.call('shell', {'command': 'echo no'}),
        ])
        self.assertTrue(all(r['result']['isError'] for r in results))
        self.assertEqual(self.server.calls, [])

    def test_no_redirect_or_token_forwarding(self):
        self.server.redirect = True
        result = self.run_messages([self.call('enote_list_todos')])[0]
        self.assertTrue(result['result']['isError'])
        self.assertEqual(len(self.server.calls), 1)

    def test_config_cannot_target_external_host(self):
        self.write_config('https://example.com')
        result = self.run_messages([self.call('enote_list_todos')])[0]
        self.assertTrue(result['result']['isError'])
        self.assertEqual(self.server.calls, [])

    def test_invalid_protocol_then_valid_request_keeps_server_alive(self):
        results = self.run_messages([[], {'jsonrpc': '2.0', 'id': 1, 'method': 'ping', 'params': []},
                                     {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}])
        self.assertEqual(results[0]['error']['code'], -32600)
        self.assertEqual(results[1]['error']['code'], -32602)
        self.assertEqual(results[2]['result'], {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
