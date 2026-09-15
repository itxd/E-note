#!/usr/bin/env python3
"""E note 本地 API 客户端。作者：韦冬 2220285589@qq.com"""
import argparse
import json
import re
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


def api_request(config_path, method, path, payload=None, timeout=8):
    config = json.loads(Path(config_path).read_text())
    base = config['baseURL'].rstrip('/')
    url = urllib.parse.urlsplit(base)
    if url.scheme != 'http' or url.hostname != '127.0.0.1' or url.username or url.password or url.path or url.query or url.fragment:
        raise ValueError('配置必须指向 http://127.0.0.1:端口')
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode()
    request = urllib.request.Request(base + path, data=data, method=method, headers={
        'Authorization': 'Bearer ' + config['token'], 'Content-Type': 'application/json'
    })
    # 本机调用不经过系统代理，也不跟随重定向把令牌发往其他地址。
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / 'Library/Application Support/ENote/api.json')
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('health', 'notes', 'todos', 'tags', 'sync-status', 'sync', 'workflows'):
        sub.add_parser(name)
    tag_read = sub.add_parser('tag')
    tag_read.add_argument('--id', required=True)
    for operation in ('tag-create', 'tag-update'):
        tag = sub.add_parser(operation)
        if operation == 'tag-update': tag.add_argument('--id', required=True)
        tag.add_argument('--name', required=operation == 'tag-create')
        tag.add_argument('--type', choices=['项目', '版本', '其他'])
        tag.add_argument('--details')
        tag.add_argument('--link')
    note = sub.add_parser('note')
    note.add_argument('--body', required=True)
    note.add_argument('--title')
    todo = sub.add_parser('todo')
    todo.add_argument('--text', required=True)
    todo.add_argument('--tag-id', action='append', help='绑定标签 UUID，可重复指定')
    todo.add_argument('--category', default='收集箱')
    todo.add_argument('--priority', choices=['normal', 'high'], default='normal')
    todo.add_argument('--due-at')
    batch = sub.add_parser('batch')
    batch.add_argument('--file', type=Path, required=True)
    complete = sub.add_parser('complete')
    complete.add_argument('--id', required=True)
    complete.add_argument('--undo', action='store_true', help='恢复为待完成')
    update = sub.add_parser('update')
    update.add_argument('--id', required=True, help='T000001、数字编号或 UUID')
    update.add_argument('--text')
    tags = update.add_mutually_exclusive_group()
    tags.add_argument('--tag-id', action='append')
    tags.add_argument('--clear-tags', action='store_true')
    update.add_argument('--category')
    update.add_argument('--priority', choices=['normal', 'high'])
    due = update.add_mutually_exclusive_group()
    due.add_argument('--due-at')
    due.add_argument('--clear-due', action='store_true')
    workflow = sub.add_parser('workflow', help='流程操作：参数从 JSON 文件读取')
    workflow.add_argument('--id', help='省略时创建流程')
    workflow.add_argument('--action', choices=['message','plan','approve','claim','heartbeat','event','finish','accept','reopen','recover'])
    workflow.add_argument('--file', type=Path, required=True, help='包含持久化 requestID 和已读取 cursor 的 JSON')
    args = parser.parse_args()

    payload = None
    method = 'GET'
    if args.command in ('tag', 'tag-create', 'tag-update'):
        from uuid import UUID
        path = '/v1/tags'
        if args.command != 'tag-create': path += '/' + str(UUID(args.id)).upper()
        if args.command != 'tag':
            method = 'POST' if args.command == 'tag-create' else 'PATCH'
            payload = {key: getattr(args, key) for key in ('name', 'type', 'details', 'link') if getattr(args, key) is not None}
            if not payload: raise ValueError('至少提供一个修改字段')
    elif args.command == 'sync-status':
        path = '/v1/sync/status'
    elif args.command == 'sync':
        method, path, payload = 'POST', '/v1/sync', {}
    elif args.command == 'workflows':
        path = '/v1/workflows'
    elif args.command == 'workflow':
        from uuid import UUID
        method, path = 'POST', '/v1/workflows'
        if args.id:
            if not args.action: raise ValueError('--id 需要 --action')
            path += '/' + str(UUID(args.id)).upper() + '/' + args.action
        elif args.action: raise ValueError('--action 需要 --id')
        payload = json.loads(args.file.read_text())
        if not isinstance(payload, dict) or not payload.get('requestID'):
            raise ValueError('流程操作需要持久化 requestID')
    elif args.command in ('health', 'notes', 'todos', 'tags'):
        path = '/v1/' + args.command
    elif args.command == 'note':
        method, path = 'POST', '/v1/notes'
        payload = {'body': args.body}
        if args.title:
            payload['title'] = args.title
    elif args.command == 'todo':
        method, path = 'POST', '/v1/todos'
        payload = {'text': args.text, 'category': args.category, 'priority': args.priority}
        if args.tag_id is not None: payload['tagIDs'] = args.tag_id
        if args.due_at:
            payload['dueAt'] = args.due_at
    elif args.command == 'batch':
        method, path = 'POST', '/v1/todos'
        payload = json.loads(args.file.read_text())
    else:
        from uuid import UUID
        identifier = args.id.upper()
        if not re.fullmatch(r'T?[0-9]+', identifier):
            identifier = str(UUID(args.id))
        method, path = 'PATCH', '/v1/todos/' + identifier
        if args.command == 'complete':
            payload = {'completed': not args.undo}
        else:
            payload = {key: getattr(args, key) for key in ('text', 'category', 'priority') if getattr(args, key) is not None}
            if args.due_at:
                payload['dueAt'] = args.due_at
            if args.tag_id is not None: payload['tagIDs'] = args.tag_id
            if args.clear_tags: payload['tagIDs'] = []
            if args.clear_due:
                payload['dueAt'] = None
            if not payload:
                raise ValueError('update 至少需要一个修改字段')
    result = api_request(args.config, method, path, payload,
                         timeout=125 if args.command in ('sync', 'workflows', 'workflow') else 8)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        print('API 错误：' + str(error.code) + ' ' + error.read().decode(errors='replace'), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError) as error:
        print('调用失败：' + str(error) + '。请检查 E note 是否运行并开启了本地 API。', file=sys.stderr)
        sys.exit(1)
