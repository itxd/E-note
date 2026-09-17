#!/usr/bin/env python3
"""E note cloud: account isolation, revisioned sync, human-approved execution leases.
作者：韦冬 2220285589@qq.com
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import ssl
import time
import threading
import uuid
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def uid():
    return str(uuid.uuid4()).upper()


def dump(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Fault(Exception):
    def __init__(self, status, message, **details):
        self.status, self.message, self.details = status, message, details


def require(condition, message, status=400):
    if not condition:
        raise Fault(status, message)


def string(value, name, maximum=200000):
    require(isinstance(value, str) and 0 < len(value.strip()) <= maximum, name + ' 无效')
    return value.strip()


class Cloud:
    def __init__(self, directory, registration_code=''):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.dbfile = self.directory / 'cloud.sqlite3'
        keyfile = self.directory / 'master.key'
        if not keyfile.exists():
            require(not self.dbfile.exists(), '数据库已存在但加密密钥缺失，拒绝生成新密钥', 500)
            fd = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(AESGCM.generate_key(bit_length=256))
        self.cipher = AESGCM(keyfile.read_bytes())
        self.registration_code = registration_code
        with self.connect() as db:
            db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
              salt BLOB NOT NULL, password BLOB NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
              todo_sequence INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, account TEXT NOT NULL,
              device TEXT NOT NULL, expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS entities(account TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL,
              revision INTEGER NOT NULL, deleted INTEGER NOT NULL, payload BLOB NOT NULL,
              PRIMARY KEY(account,id));
            CREATE TABLE IF NOT EXISTS requests(account TEXT NOT NULL, id TEXT NOT NULL,
              hash TEXT NOT NULL, result BLOB NOT NULL, PRIMARY KEY(account,id));
            CREATE TABLE IF NOT EXISTS workflows(account TEXT NOT NULL, id TEXT NOT NULL,
              todo TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(account,id));
            CREATE TABLE IF NOT EXISTS attempts(key TEXT PRIMARY KEY, count INTEGER NOT NULL, until REAL NOT NULL);
            ''')
        os.chmod(self.dbfile, 0o600)

    def connect(self):
        db = sqlite3.connect(self.dbfile, timeout=20)
        db.row_factory = sqlite3.Row
        return db

    @contextmanager
    def transaction(self):
        db = self.connect()
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def seal(self, value, context):
        nonce = secrets.token_bytes(12)
        return nonce + self.cipher.encrypt(nonce, dump(value).encode(), context.encode())

    def open(self, value, context):
        return json.loads(self.cipher.decrypt(value[:12], value[12:], context.encode()))

    def tick(self, db, account):
        db.execute('UPDATE accounts SET revision=revision+1 WHERE id=?', (account,))
        return db.execute('SELECT revision FROM accounts WHERE id=?', (account,)).fetchone()[0]

    def snapshot(self, db, account):
        revision = db.execute('SELECT revision FROM accounts WHERE id=?', (account,)).fetchone()[0]
        entities = [dict(id=r['id'], kind=r['kind'], revision=r['revision'], deleted=bool(r['deleted']),
                         payload=self.open(r['payload'], account + r['id']))
                    for r in db.execute('SELECT * FROM entities WHERE account=? ORDER BY id', (account,))]
        flows = [self.open(r['data'], account + r['id'])
                 for r in db.execute('SELECT * FROM workflows WHERE account=? ORDER BY id', (account,))]
        return dict(cursor=revision, entities=entities, workflows=flows, serverTime=time.time())

    def put(self, db, account, entity):
        revision = self.tick(db, account)
        db.execute('INSERT OR REPLACE INTO entities VALUES(?,?,?,?,?,?)',
                   (account, entity['id'], entity['kind'], revision, int(entity['deleted']),
                    self.seal(entity['payload'], account + entity['id'])))
        return revision

    def entity(self, db, account, identifier):
        r = db.execute('SELECT * FROM entities WHERE account=? AND id=?', (account, identifier)).fetchone()
        require(r is not None and not r['deleted'], '记录不存在或已删除', 404)
        return dict(id=r['id'], kind=r['kind'], revision=r['revision'], deleted=False,
                    payload=self.open(r['payload'], account + r['id']))

    def auth(self, db, token):
        row = db.execute('SELECT * FROM sessions WHERE token=? AND expires>?',
                         (digest(token), time.time())).fetchone()
        require(row is not None, '登录已失效，请重新登录', 401)
        return row['account'], row['device']

    def rate_limit(self, key):
        with self.transaction() as db:
            now = time.time()
            db.execute('DELETE FROM attempts WHERE until<?', (now,))
            r = db.execute('SELECT * FROM attempts WHERE key=?', (key,)).fetchone()
            require(r is None or r['count'] < 12, '登录尝试过多，请 15 分钟后再试', 429)
            db.execute('INSERT INTO attempts VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1',
                       (key, now + 900))

    def login(self, path, data, peer):
        self.rate_limit('auth:' + peer)
        username = string(data.get('username'), '账号', 100).lower()
        password = string(data.get('password'), '密码', 256)
        device = string(data.get('deviceID'), '设备编号', 100)
        with self.transaction() as db:
            if path == '/v1/auth/register':
                require(self.registration_code and hmac.compare_digest(str(data.get('registrationCode', '')),
                                                                       self.registration_code), '邀请码无效', 403)
                require(len(password) >= 10, '密码至少 10 个字符')
                salt = secrets.token_bytes(32)
                hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 600000)
                try:
                    db.execute('INSERT INTO accounts(id,username,salt,password) VALUES(?,?,?,?)',
                               (uid(), username, salt, hashed))
                except sqlite3.IntegrityError:
                    raise Fault(409, '账号已存在')
            row = db.execute('SELECT * FROM accounts WHERE username=?', (username,)).fetchone()
            salt = row['salt'] if row else b'nonexistent-account-timing-salt!!'
            hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 600000)
            require(row is not None and hmac.compare_digest(hashed, row['password']), '账号或密码错误', 401)
            token = secrets.token_urlsafe(48)
            db.execute('DELETE FROM sessions WHERE expires<?', (time.time(),))
            db.execute('INSERT INTO sessions VALUES(?,?,?,?)', (digest(token), row['id'], device, time.time()+90*86400))
            return dict(accountID=row['id'], username=username, token=token)

    def validate_entity(self, entity):
        require(isinstance(entity, dict), '变更必须为对象')
        identifier = string(entity.get('id'), 'id', 36)
        try:
            require(str(uuid.UUID(identifier)).upper() == identifier, 'id 必须为大写 UUID')
        except ValueError:
            raise Fault(400, 'id 必须为 UUID')
        require(entity.get('kind') in ('note', 'todo', 'tag'), '未知记录类型')
        require(type(entity.get('baseRevision')) is int and entity['baseRevision'] >= 0, 'baseRevision 无效')
        require(type(entity.get('deleted')) is bool and isinstance(entity.get('payload'), dict), '记录格式无效')
        payload = entity['payload']
        require(len(dump(payload)) <= 300000, '单条记录过大', 413)
        if entity['deleted']:
            return
        if entity['kind'] == 'tag':
            string(payload.get('name'), 'name', 80)
            require(payload.get('type') in ('项目', '版本', '其他'), '标签类型无效')
            require(isinstance(payload.get('details'), str) and len(payload['details']) <= 20000, '标签说明无效')
            require(isinstance(payload.get('link'), str) and len(payload['link']) <= 2000, '标签链接无效')
        elif entity['kind'] == 'todo':
            string(payload.get('text'), 'text', 10000)
            string(payload.get('category'), 'category', 80)
            require(payload.get('priority') in ('normal', 'high') and type(payload.get('completed')) is bool, '待办状态无效')
            ids = payload.get('tagIDs', [])
            require(isinstance(ids, list) and len(ids) <= 100, '标签绑定无效')
            for identifier in ids:
                try:
                    require(isinstance(identifier, str) and str(uuid.UUID(identifier)).upper() == identifier, '标签 ID 无效')
                except (ValueError, AttributeError):
                    raise Fault(400, '标签 ID 无效')
            for field in ('completedAt', 'archivedAt', 'archiveRestoredAt'):
                require(payload.get(field) is None or type(payload[field]) in (int, float), '归档时间无效')
            require(payload.get('dueAt') is None or isinstance(payload['dueAt'], (int, float)), 'dueAt 必须为 Unix 时间')
        else:
            require(isinstance(payload.get('body'), str) and len(payload['body']) <= 200000, '正文无效')
            string(payload.get('title'), 'title', 200)
            require(type(payload.get('isArchived')) is bool and type(payload.get('isPinned')) is bool, '便签状态无效')
            require(isinstance(payload.get('createdAt'), (int, float)) and isinstance(payload.get('modifiedAt'), (int, float)), '时间无效')

    def sync(self, db, account, data):
        changes = data.get('changes', [])
        require(isinstance(changes, list) and len(changes) <= 1000, '每批最多 1000 条变更')
        for change in changes:
            self.validate_entity(change)
        require(len({e['id'] for e in changes}) == len(changes), '批次中 id 重复')
        conflicts = []
        for e in changes:
            r = db.execute('SELECT revision,kind FROM entities WHERE account=? AND id=?', (account,e['id'])).fetchone()
            if (r['revision'] if r else 0) != e['baseRevision']:
                conflicts.append(e['id'])
            require(r is None or r['kind'] == e['kind'], '不可修改记录类型')
        if conflicts:
            raise Fault(409, '记录已更新，请合并后重试', conflicts=conflicts, snapshot=self.snapshot(db, account))
        for e in changes:
            payload = dict(e['payload'])
            if e['kind'] == 'todo' and not e['deleted']:
                r = db.execute('SELECT payload FROM entities WHERE account=? AND id=?', (account,e['id'])).fetchone()
                if r:
                    payload['number'] = self.open(r['payload'], account+e['id'])['number']
                else:
                    db.execute('UPDATE accounts SET todo_sequence=todo_sequence+1 WHERE id=?', (account,))
                    payload['number'] = db.execute('SELECT todo_sequence FROM accounts WHERE id=?', (account,)).fetchone()[0]
            self.put(db, account, dict(e, payload=payload))
        return self.snapshot(db, account)

    def save_flow(self, db, account, flow):
        flow['revision'] = self.tick(db, account)
        flow['updatedAt'] = time.time()
        db.execute('INSERT OR REPLACE INTO workflows VALUES(?,?,?,?)',
                   (account,flow['id'],flow['todoID'],self.seal(flow, account+flow['id'])))

    def append_record(self, db, account, flow, text):
        note = self.entity(db, account, flow['noteID'])
        note['payload']['body'] += '\n\n' + text
        require(len(note['payload']['body']) <= 200000, '执行记录已达便签容量，请缩短本次记录', 413)
        note['payload']['modifiedAt'] = time.time()
        self.put(db, account, note)

    def workflow(self, db, account, device, path, data):
        current = db.execute('SELECT revision FROM accounts WHERE id=?', (account,)).fetchone()[0]
        parts = path.strip('/').split('/')
        action = parts[-1]
        # Heartbeats/logs carry lease tokens. All intent changes must be based on a fresh sync.
        if action not in ('heartbeat', 'event', 'finish'):
            require(type(data.get('cursor')) is int and data['cursor'] == current, '请先同步最新状态再操作', 409)
        if path == '/v1/workflows':
            todo = self.entity(db, account, string(data.get('todoID'), 'todoID', 36))
            require(todo['kind'] == 'todo' and not todo['payload']['completed'] and not todo['payload'].get('archivedAt'), '只能讨论未完成 TODO')
            snapshot = self.snapshot(db, account)
            existing_flow = next((f for f in snapshot['workflows'] if f['todoID'] == todo['id']), None)
            if existing_flow:
                return dict(workflow=existing_flow, snapshot=snapshot)
            linked = sorted((n for n in snapshot['entities'] if n['kind'] == 'note' and not n['deleted']
                             and n['payload'].get('linkedTodoID') == todo['id']),
                            key=lambda n: (n['payload'].get('deletedAt') is not None,
                                           n['payload'].get('createdAt', 0), n['id']))
            code = 'T' + str(todo['payload']['number']).zfill(6)
            note_id = str(uuid.UUID(bytes=hashlib.sha256(('enote-linked-note:' + todo['id'].upper()).encode()).digest()[:16])).upper()
            flow = dict(id=uid(), todoID=todo['id'], noteID=linked[0]['id'] if linked else note_id, state='discussing',
                        revision=0, planVersion=0, plan='', messages=[], events=[], createdAt=time.time())
            note = linked[0] if linked else dict(id=flow['noteID'], kind='note', deleted=False,
                        payload=dict(title=code+' · '+todo['payload']['text'][:30],
                                     body=code+' · '+todo['payload']['text']+'\n关联待办：'+code,
                                     colorName='雾紫', createdAt=time.time(), modifiedAt=time.time(),
                                     isPinned=False, isArchived=False, deletedAt=None,
                                     linkedTodoID=todo['id']))
            note['payload'].update(workflowID=flow['id'], deletedAt=None, isArchived=False)
            self.put(db, account, note)
            self.save_flow(db, account, flow)
            return dict(workflow=flow, snapshot=self.snapshot(db, account))
        require(len(parts) == 4, '流程接口不存在', 404)
        row = db.execute('SELECT data FROM workflows WHERE account=? AND id=?', (account,parts[2])).fetchone()
        require(row is not None, '流程不存在', 404)
        flow = self.open(row['data'], account+parts[2])
        state = flow['state']
        if action in ('heartbeat','event','finish'):
            require(state == 'running' and flow.get('deviceID') == device and
                    hmac.compare_digest(flow.get('leaseToken',''), str(data.get('leaseToken',''))) and
                    (action == 'finish' or flow.get('leaseUntil',0) > time.time()), '执行锁失效；停止执行并等待人工确认', 409)
            flow['leaseUntil'] = time.time()+90
            if action == 'event':
                text = string(data.get('text'), '过程记录', 8000)
                flow['events'].append(dict(at=time.time(), text=text))
                self.append_record(db, account, flow, '过程记录\n'+text)
            if action == 'finish':
                require(type(data.get('success')) is bool, 'success 必须为布尔值')
                result = string(data.get('result'), '执行结果', 16000)
                flow['state'] = 'awaiting_result' if data['success'] else 'failed'
                flow['result'] = result
                self.append_record(db, account, flow, '执行结果 · 等待用户验收\n'+result)
        elif action == 'message':
            require(state in ('discussing','awaiting_approval','approved','failed','interrupted'), '当前阶段不能修改讨论', 409)
            role = data.get('role')
            require(role in ('user','assistant'), 'role 无效')
            text = string(data.get('text'), '讨论内容', 12000)
            flow['messages'].append(dict(role=role, text=text, at=time.time()))
            flow['state'] = 'discussing'
            self.append_record(db, account, flow, ('用户' if role == 'user' else 'AI')+'\n'+text)
        elif action == 'plan':
            require(state in ('discussing','awaiting_approval'), '请先讨论或重新打开流程', 409)
            require(any(m['role']=='user' for m in flow['messages']), '请先与用户确认需求', 409)
            plan = string(data.get('plan'), '实施方案', 24000)
            workspace = string(data.get('workspace'), '工作目录', 2000)
            require(workspace.startswith('/'), '工作目录必须为绝对路径')
            flow.update(plan=plan, workspace=workspace, state='awaiting_approval',
                        planVersion=flow['planVersion']+1, approvalCode=secrets.token_hex(4))
            self.append_record(db, account, flow, '实施方案 v'+str(flow['planVersion'])+'\n工作目录：'+workspace+'\n'+plan)
            flow['planNoteRevision'] = self.entity(db, account, flow['noteID'])['revision']
        elif action == 'approve':
            require(state == 'awaiting_approval', '尚无待确认方案', 409)
            require(data.get('planVersion') == flow['planVersion'] and
                    hmac.compare_digest(str(data.get('approvalCode','')), flow['approvalCode']), '方案版本或确认码不符', 409)
            note = self.entity(db, account, flow['noteID'])
            require(note['revision'] == flow['planNoteRevision'], '方案便签已被修改，请重新生成方案再确认', 409)
            todo = self.entity(db, account, flow['todoID'])
            require(not todo['payload']['completed'] and not todo['payload'].get('archivedAt'), 'TODO 已完成或归档', 409)
            flow.update(state='approved', approvedTodoRevision=todo['revision'], approvedBy=string(data.get('actor'), '确认人', 200))
        elif action == 'claim':
            require(state == 'approved', '任务未获确认或已被其他设备领取', 409)
            todo = self.entity(db, account, flow['todoID'])
            note = self.entity(db, account, flow['noteID'])
            require(todo['revision'] == flow['approvedTodoRevision'] and not todo['payload']['completed'] and not todo['payload'].get('archivedAt') and
                    note['revision'] == flow['planNoteRevision'], 'TODO 或实施方案已变化，请重新讨论确认', 409)
            for other in db.execute('SELECT data,id FROM workflows WHERE account=? AND todo=?', (account,flow['todoID'])):
                f = self.open(other['data'], account+other['id'])
                # Expired processes may still be alive; never steal automatically.
                require(f['state'] != 'running', '该 TODO 已有执行流程；需人工确认原进程已停止', 409)
            flow.update(state='running', deviceID=device, leaseToken=secrets.token_urlsafe(32),
                        leaseUntil=time.time()+90, executionID=uid())
            self.append_record(db, account, flow, '开始执行\n设备：'+device+'\n执行编号：'+flow['executionID'])
        elif action == 'recover':
            require(state == 'running' and flow['leaseUntil'] < time.time(), '执行锁尚未过期', 409)
            require(data.get('confirmedStopped') is True, '必须确认旧进程已经停止', 409)
            flow.update(state='interrupted', leaseToken='', leaseUntil=0)
            self.append_record(db, account, flow, '人工确认旧执行进程已停止；重新执行前需重新讨论和确认方案。')
        elif action == 'accept':
            require(state == 'awaiting_result', '没有待验收结果', 409)
            require(data.get('accepted') is True, '验收未通过时请使用 reopen')
            todo = self.entity(db, account, flow['todoID'])
            require(todo['revision'] == flow['approvedTodoRevision'], 'TODO 已发生变化，请核对后重新讨论', 409)
            todo['payload']['completed'] = True
            todo['payload']['completedAt'] = time.time()
            self.put(db, account, todo)
            flow['state'] = 'completed'
            self.append_record(db, account, flow, '用户已验收，TODO 标记完成。')
        elif action == 'reopen':
            require(state not in ('running','completed'), '当前阶段不能重新讨论', 409)
            flow['state'] = 'discussing'
            self.append_record(db, account, flow, '重新讨论\n'+string(data.get('reason'), '原因', 8000))
        else:
            raise Fault(404, '流程操作不存在')
        self.save_flow(db, account, flow)
        return dict(workflow=flow, snapshot=self.snapshot(db, account))

    def handle(self, method, path, data, token='', peer='local'):
        require(isinstance(data, dict), '需要 JSON 对象')
        if method == 'GET' and path == '/health':
            return dict(app='E note cloud', version=1)
        if method == 'POST' and path in ('/v1/auth/register','/v1/auth/login'):
            return self.login(path, data, peer)
        with self.transaction() as db:
            account, device = self.auth(db, token)
            if method == 'POST' and path == '/v1/auth/logout':
                db.execute('DELETE FROM sessions WHERE token=?', (digest(token),))
                return dict(ok=True)
            if method == 'GET' and path == '/v1/sync':
                return self.snapshot(db, account)
            require(method == 'POST', '接口不存在', 404)
            request_id = string(data.get('requestID'), 'requestID', 100)
            request_hash = digest(path+dump(data))
            old = db.execute('SELECT * FROM requests WHERE account=? AND id=?', (account,request_id)).fetchone()
            if old:
                require(old['hash'] == request_hash, 'requestID 已用于不同请求', 409)
                cached = self.open(old['result'], account+request_id)
                if cached.get('_syncAck'):
                    return self.snapshot(db, account)
                if '_workflowAck' in cached:
                    return dict(workflow=cached['_workflowAck'], snapshot=self.snapshot(db, account))
                return cached
            if path == '/v1/sync':
                result = self.sync(db, account, data)
            elif path.startswith('/v1/workflows'):
                result = self.workflow(db, account, device, path, data)
            else:
                raise Fault(404, '接口不存在')
            # Keep durable request identities, without duplicating a complete account snapshot on every heartbeat.
            acknowledgement = dict(_syncAck=True) if path == '/v1/sync' else dict(_workflowAck=result['workflow'])
            if path.endswith('/heartbeat'):
                acknowledgement = dict(_workflowAck={k: result['workflow'][k] for k in ('id','state','leaseUntil','revision')})
            db.execute('INSERT INTO requests VALUES(?,?,?,?)',
                       (account,request_id,request_hash,self.seal(acknowledgement, account+request_id)))
            return result


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.connection.settimeout(20)

    def log_message(self, *_):
        pass  # Never log credentials or note contents.

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        try:
            require(not self.headers.get('Origin'), '不接受浏览器跨站请求', 403)
            require(not self.headers.get('Transfer-Encoding'), '不支持分块请求')
            lengths = self.headers.get_all('Content-Length', [])
            require(len(lengths) <= 1, '重复 Content-Length')
            length = int(lengths[0]) if lengths else 0
            require(0 <= length <= 8*1024*1024, '请求过大', 413)
            if self.command == 'POST':
                require(self.headers.get('Content-Type','').split(';')[0] == 'application/json', '需要 application/json', 415)
            raw = self.rfile.read(length) if length else b'{}'
            require(len(raw) == length or length == 0, '请求不完整')
            data = json.loads(raw)
            auth = self.headers.get('Authorization','')
            token = auth[7:] if auth.startswith('Bearer ') else ''
            result = self.server.cloud.handle(self.command, self.path, data, token, self.client_address[0])
            status = 200
        except Fault as e:
            status, result = e.status, dict(error=e.message, **e.details)
        except (ValueError, UnicodeError):
            status, result = 400, dict(error='无效 JSON 或请求长度')
        except Exception:
            status, result = 500, dict(error='服务器处理失败；使用相同 requestID 重试')
        output = dump(result).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(output)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(output)
        self.close_connection = True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args, **kwargs)
    def get_request(self):
        request, address = super().get_request()
        request.settimeout(10)
        return request, address
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try: super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try:
            if getattr(self, 'tls_context', None):
                request = self.tls_context.wrap_socket(request, server_side=True)
            super().process_request_thread(request, client_address)
        except (ssl.SSLError, OSError):
            self.shutdown_request(request)
        finally: self.slots.release()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--data', default=os.environ.get('ENOTE_CLOUD_DATA','/var/lib/enote'))
    p.add_argument('--host', default='127.0.0.1')
    p.add_argument('--port', type=int, default=49200)
    p.add_argument('--cert')
    p.add_argument('--key')
    args = p.parse_args()
    require(args.host in ('127.0.0.1','::1') or (args.cert and args.key), '公网监听必须配置 TLS')
    cloud = Cloud(args.data, os.environ.get('ENOTE_REGISTRATION_CODE',''))
    server = Server((args.host,args.port), Handler)
    server.cloud = cloud
    if args.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(args.cert,args.key)
        server.tls_context = ctx
    print('E note cloud listening', args.host, args.port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
