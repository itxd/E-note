"""使用隔离数据、设置和随机端口验证真实 HTTP 服务与客户端。"""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / 'skills/e-note/scripts/e_note.py'
BINARY = ROOT / 'build/enote-tests'

with tempfile.TemporaryDirectory(prefix='enote-tests-') as directory:
    data = Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    suite = 'com.weidong.enote.tests.' + uuid.uuid4().hex
    env = dict(os.environ, NOTY_DATA_DIR=str(data), ENOTE_SETTINGS_SUITE=suite, ENOTE_API_PORT=str(port))
    process = None
    def start():
        return subprocess.Popen([str(BINARY), 'serve'], cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    def wait_config():
        for _ in range(100):
            if (data / 'api.json').exists():
                return json.loads((data / 'api.json').read_text())
            if process.poll() is not None:
                raise AssertionError('server exited')
            time.sleep(.05)
        raise AssertionError('server did not start')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(method, path, payload=None, token=True, headers=None, raw=None):
        h = {'Content-Type': 'application/json'}
        if token:
            h['Authorization'] = 'Bearer ' + config['token']
        if headers:
            h.update(headers)
        body = raw if raw is not None else (None if payload is None else json.dumps(payload).encode())
        req = urllib.request.Request(config['baseURL'] + path, data=body, headers=h, method=method)
        try:
            with opener.open(req, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)
    def command(value):
        process.stdin.write((value + '\n').encode()); process.stdin.flush()
        time.sleep(.2)
    try:
        subprocess.run([str(BINARY)], cwd=ROOT, env=env, check=True)
        process = start()
        config = wait_config()
        listeners = subprocess.check_output(['lsof', '-nP', '-a', '-p', str(process.pid), '-iTCP', '-sTCP:LISTEN'], text=True)
        assert '127.0.0.1:' + str(port) in listeners and '*:' not in listeners
        assert (data / 'api.json').stat().st_mode & 0o777 == 0o600
        assert (data / 'api-token').stat().st_mode & 0o777 == 0o600
        assert request('GET', '/v1/health')[0] == 200
        migrated = request('GET', '/v1/todos')[1]['items']
        assert all(item['number'] > 0 and item['code'].startswith('T') for item in migrated)
        assert len({item['number'] for item in migrated}) == len(migrated)
        assert request('GET', '/v1/notes', token=False)[0] == 401
        assert request('GET', '/v1/notes', headers={'Authorization': 'Bearer wrong'})[0] == 401
        assert request('POST', '/v1/todos', {'text': 'blocked'}, headers={'Origin': 'https://example.com'})[0] == 403
        assert request('POST', '/v1/todos', raw=b'{invalid')[0] == 400
        assert request('POST', '/v1/todos', {'text': 'x'}, headers={'Content-Type': 'text/plain'})[0] == 415
        assert request('POST', '/v1/todos', {'text': 'x', 'completed': 1})[0] == 400
        assert request('POST', '/v1/todos', {'text': 'x', 'dueAt': 'tomorrow'})[0] == 400
        assert request('POST', '/v1/todos', {'text': 'x', 'priority': 'urgent'})[0] == 400
        assert request('POST', '/v1/todos', {'items': []})[0] == 400
        assert request('GET', '/missing')[0] == 404
        code, created = request('POST', '/v1/notes', {'title': 'API 测试', 'body': '外部程序创建的便签'})
        assert code == 201 and created['note']['title'] == 'API 测试'
        code, result = request('POST', '/v1/todos', {'items': [
            {'text': 'http-secret-task', 'category': '工作', 'priority': 'high', 'dueAt': '2026-09-18T17:00:00+08:00'},
            {'text': '读书', 'category': '学习'}]})
        assert code == 201 and len(result['items']) == 2
        item = result['items'][0]
        assert item['number'] > 0 and item['code'] == 'T' + str(item['number']).zfill(6)
        assert request('GET', '/v1/todos/' + item['code'])[1]['item']['id'] == item['id']
        assert request('GET', '/v1/todos/' + str(item['number']))[1]['item']['id'] == item['id']
        code, edited = request('PATCH', '/v1/todos/' + item['code'], {'text': '按编号修改的任务内容'})
        assert code == 200 and edited['item']['text'] == '按编号修改的任务内容' and edited['item']['id'] == item['id']
        assert request('PATCH', '/v1/todos/' + item['code'], {'number': 999})[0] == 400
        before_note_todo = len(request('GET', '/v1/todos')[1]['items'])
        _, text_note = request('POST', '/v1/notes', {'body': '☐ 普通 note 中的 TODO'})
        assert len(request('GET', '/v1/todos')[1]['items']) == before_note_todo
        assert request('PATCH', '/v1/todos/' + text_note['note']['id'], {'text': '不可修改'})[0] == 404
        code, result = request('PATCH', '/v1/todos/' + item['id'], {'completed': True, 'dueAt': None})
        assert code == 200 and result['item']['completed'] and result['item']['dueAt'] is None
        assert result['item']['category'] == '工作'
        baseline = len(request('GET', '/v1/todos')[1]['items'])
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda i: request('POST', '/v1/todos', {'text': '并发任务 ' + str(i)}), range(12)))
        assert all(code == 201 for code, _ in results)
        assert len(request('GET', '/v1/todos')[1]['items']) == baseline + 12
        command('todo-off')
        assert request('GET', '/v1/todos')[1]['enabled'] is False
        assert request('POST', '/v1/todos', {'text': '关闭常驻仍保留'})[0] == 201
        assert request('GET', '/v1/todos')[1]['enabled'] is False
        command('todo-on')
        assert request('GET', '/v1/notes')[1]['notes'][0]['kind'] == 'todoList'
        output = subprocess.check_output(['python3', str(CLIENT), '--config', str(data / 'api.json'), 'todo', '--text', 'skill 客户端任务', '--category', '生活'], cwd=ROOT)
        client_item = json.loads(output)['items'][0]
        assert client_item['category'] == '生活'
        output = subprocess.check_output(['python3', str(CLIENT), '--config', str(data / 'api.json'), 'update', '--id', client_item['code'], '--text', 'skill 按编号修改后的任务'], cwd=ROOT)
        assert json.loads(output)['item']['text'] == 'skill 按编号修改后的任务'
        output = subprocess.check_output(['python3', str(CLIENT), '--config', str(data / 'api.json'), 'complete', '--id', client_item['code']], cwd=ROOT)
        assert json.loads(output)['item']['completed'] is True
        persisted = request('GET', '/v1/todos')[1]
        disk = (data / 'notes.json').read_text()
        assert 'http-secret-task' not in disk and 'skill 客户端任务' not in disk
        # 分片 HTTP 请求必须等完整正文后才写入。
        payload = json.dumps({'text': '分片提交'}).encode()
        wire = (f'POST /v1/todos HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {config["token"]}\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n').encode()
        with socket.create_connection(('127.0.0.1', port), timeout=5) as sock:
            sock.sendall(wire + payload[:4]); time.sleep(.05); sock.sendall(payload[4:])
            response = sock.recv(4096)
            assert b'201 OK' in response
        with socket.create_connection(('127.0.0.1', port), timeout=5) as sock:
            sock.sendall(wire.replace(str(len(payload)).encode() + b'\r\n\r\n', b'2000000\r\n\r\n'))
            assert b'413 Error' in sock.recv(4096)
        command('api-off')
        assert not (data / 'api.json').exists()
        try:
            socket.create_connection(('127.0.0.1', port), timeout=.3).close()
            raise AssertionError('API still accepting after disabled')
        except OSError:
            pass
        command('api-on')
        assert wait_config()['token'] == config['token']
        assert request('GET', '/v1/health')[0] == 200
        command('api-off')
        process.terminate(); process.wait(timeout=5)
        # 偏好中已关闭 API，重启仍然关闭，随后通过测试宿主显式打开。
        process = start(); command('api-on'); config2 = wait_config()
        assert config2['token'] == config['token']
        reloaded = request('GET', '/v1/todos')[1]
        assert reloaded['noteID'] == persisted['noteID']
        assert {item['id'] for item in persisted['items']} <= {item['id'] for item in reloaded['items']}
        before_numbers = {item['id']: item['code'] for item in persisted['items']}
        after_numbers = {item['id']: item['code'] for item in reloaded['items']}
        assert all(after_numbers[key] == value for key, value in before_numbers.items())
        assert len({item['number'] for item in reloaded['items']}) == len(reloaded['items'])
        newest = request('POST', '/v1/todos', {'text': '重启后继续编号'})[1]['items'][0]
        assert newest['number'] > max(item['number'] for item in reloaded['items'])
        command('api-off')
        process.terminate(); process.wait(timeout=5); process = None
        subprocess.run([str(BINARY), 'preview'], cwd=ROOT, env=env, check=True)
        subprocess.run([str(BINARY), 'todo-features'], cwd=ROOT, env=env, check=True)
        print('PASS: HTTP 鉴权、校验、批量/并发、分类/完成、分片与请求大小限制、开关、客户端、加密与重启持久化；已生成深浅色界面预览')
    finally:
        if process is not None and process.poll() is None:
            process.terminate(); process.wait(timeout=5)
        subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
