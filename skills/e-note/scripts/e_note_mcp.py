#!/usr/bin/env python3
"""E note STDIO MCP adapter. 作者：韦冬 2220285589@qq.com

Only fixed E note operations are exposed; no arbitrary URLs, files or shell commands.
The host starts this local connector and communicates through stdin/stdout.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import urllib.error
from uuid import UUID

from e_note import api_request


TEXT = {'type': 'string'}
TODO_FIELDS = {
    'text': {'type': 'string', 'minLength': 1},
    'category': dict(TEXT, description='旧版兼容字段，优先使用 tagIDs'),
    'tagIDs': {'type': 'array', 'items': TEXT, 'maxItems': 100, 'description': '标签 UUID 数组；先读取标签列表；空数组清除绑定'},
    'priority': {'type': 'string', 'enum': ['normal', 'high']},
    'dueAt': {'type': ['string', 'null'], 'description': '带时区的 ISO 8601 时间；null 清除期限'},
}


TAG_FIELDS = {'name': {'type': 'string', 'minLength': 1},
              'type': {'type': 'string', 'enum': ['项目', '版本', '其他']},
              'details': TEXT, 'link': TEXT}


def tool(name, description, properties=None, required=None, read_only=False):
    return {
        'name': name, 'description': description,
        'inputSchema': {'type': 'object', 'properties': properties or {},
                        'required': required or [], 'additionalProperties': False},
        'annotations': {'readOnlyHint': read_only, 'openWorldHint': False},
    }


TOOLS = [
    tool('enote_list_tags', '读取标签资料，按最新修改排序，含 UUID、名称、类型、说明和链接。', read_only=True),
    tool('enote_get_tag', '按 UUID 读取标签完整资料。', {'id': TEXT}, ['id'], read_only=True),
    tool('enote_create_tag', '按用户要求创建可复用的项目或版本标签。', TAG_FIELDS, ['name']),
    tool('enote_update_tag', '先读取标签，再按用户要求修改资料；所有绑定 TODO 共用最新资料。', dict(TAG_FIELDS, id=TEXT), ['id']),
    tool('enote_health', '检查本机 E note API 是否可用。', read_only=True),
    tool('enote_list_todos', '读取 E note 独立 TODOList，包括编号、内容、分类、完成状态和期限。', read_only=True),
    tool('enote_list_notes', '读取 E note 普通便签。', read_only=True),
    tool('enote_sync_status', '查看 E note 是否登录及同步状态；未登录时仍可使用本机便签和 TODO。', read_only=True),
    tool('enote_sync', '同步当前登录账号；冲突或失败时暂停跨设备操作。'),
    tool('enote_create_note', '按用户要求创建普通便签；超时后先查询，不自动重复创建。',
         {'title': TEXT, 'body': TEXT}, ['body']),
    tool('enote_create_todo', '按用户要求添加一条独立 TODO；超时后先查询，不自动重复创建。', TODO_FIELDS, ['text']),
    tool('enote_update_todo', '按已有编号或 UUID 修改 TODO。先核对目标；关联执行任务需用户验收后才能完成。',
         dict(TODO_FIELDS, id={'type': 'string', 'description': 'T000001、数字编号或 UUID'},
              completed={'type': 'boolean'}, archived={'type': 'boolean'}), ['id']),
]


NOTE_FIELDS = {'title': {'type': 'string', 'minLength': 1, 'maxLength': 40},
               'body': {'type': 'string', 'minLength': 1, 'maxLength': 200000},
               'isPinned': {'type': 'boolean'}, 'isArchived': {'type': 'boolean'}}
TOOLS += [
    tool('enote_get_note', '按 UUID 读取普通便签。', {'id': TEXT}, ['id'], True),
    tool('enote_update_note', '修改便签；body 包含首行标题，title 替换首行。先读取目标。', dict(NOTE_FIELDS, id=TEXT), ['id']),
    tool('enote_delete_note', '将普通便签移到回收站，可恢复。', {'id': TEXT}, ['id']),
    tool('enote_restore_note', '从回收站恢复便签。', {'id': TEXT}, ['id']),
    tool('enote_get_todo', '按 T 编号或 UUID 读取待办。', {'id': TEXT}, ['id'], True),
    tool('enote_delete_todo', '永久删除已完成或已归档待办；未完成待办不可删除。', {'id': TEXT}, ['id']),
    tool('enote_delete_tag', '删除标签；必须先解除所有待办的绑定。', {'id': TEXT}, ['id']),
]
for spec in TOOLS:
    spec['annotations']['destructiveHint'] = any(word in spec['name'] for word in ('update', 'delete'))
    if spec['name'] == 'enote_list_notes':
        spec['inputSchema']['properties'] = {'state': {'type': 'string', 'enum': ['active', 'archived', 'deleted', 'all']}}
    if spec['name'] == 'enote_create_note':
        spec['inputSchema']['properties'] = {key: NOTE_FIELDS[key] for key in ('title', 'body')}


def validate(arguments, schema):
    if not isinstance(arguments, dict):
        raise ValueError('arguments 必须为对象')
    if set(arguments) - set(schema['properties']):
        raise ValueError('包含不支持的参数')
    if set(schema['required']) - set(arguments):
        raise ValueError('缺少必需参数')
    for key, value in arguments.items():
        field = schema['properties'][key]
        types = field['type'] if isinstance(field['type'], list) else [field['type']]
        actual = 'null' if value is None else 'boolean' if isinstance(value, bool) else 'string' if isinstance(value, str) else 'array' if isinstance(value, list) else 'other'
        if actual not in types or ('enum' in field and value not in field['enum']):
            raise ValueError('参数类型或取值不正确：' + key)
        if isinstance(value, list) and (len(value) > field.get('maxItems', 100) or not all(isinstance(v, str) for v in value)):
            raise ValueError('数组参数无效：' + key)
        if isinstance(value, str) and (len(value.strip()) < field.get('minLength', 0) or len(value) > field.get('maxLength', 200000)):
            raise ValueError('参数不能为空：' + key)


def invoke(name, arguments, config):
    spec = next((item for item in TOOLS if item['name'] == name), None)
    if spec is None:
        raise ValueError('未知 E note 工具')
    validate(arguments, spec['inputSchema'])
    if name == 'enote_list_notes':
        state = arguments.get('state', 'active')
        result = api_request(config, 'GET', '/v1/notes/all')
        result['notes'] = [note for note in result['notes'] if note.get('kind') == 'note' and (
            state == 'all' or
            (state == 'deleted' and note.get('deletedAt') is not None) or
            (state == 'archived' and note.get('isArchived') and note.get('deletedAt') is None) or
            (state == 'active' and not note.get('isArchived') and note.get('deletedAt') is None))]
        return result
    operations = {
        'enote_get_note': ('GET', 'notes'), 'enote_update_note': ('PATCH', 'notes'),
        'enote_delete_note': ('DELETE', 'notes'), 'enote_restore_note': ('POST', 'notes'),
        'enote_get_todo': ('GET', 'todos'), 'enote_delete_todo': ('DELETE', 'todos'),
        'enote_delete_tag': ('DELETE', 'tags'),
    }
    if name in operations:
        method, resource = operations[name]
        payload = dict(arguments)
        identifier = payload.pop('id').upper()
        if resource != 'todos' or not re.fullmatch(r'T?[0-9]+', identifier):
            identifier = str(UUID(identifier)).upper()
        if method == 'PATCH' and not payload:
            raise ValueError('至少提供一个修改字段')
        path = '/v1/' + resource + '/' + identifier
        if name == 'enote_restore_note':
            path += '/restore'
        return api_request(config, method, path, payload if method in ('PATCH', 'POST') else None)
    reads = {'enote_list_tags': '/v1/tags', 'enote_health': '/v1/health', 'enote_list_todos': '/v1/todos',
             'enote_list_notes': '/v1/notes', 'enote_sync_status': '/v1/sync/status'}
    if name in reads:
        return api_request(config, 'GET', reads[name])
    if name == 'enote_create_tag':
        return api_request(config, 'POST', '/v1/tags', arguments)
    if name in ('enote_get_tag', 'enote_update_tag'):
        payload = dict(arguments)
        identifier = str(UUID(payload.pop('id'))).upper()
        if name == 'enote_get_tag':
            return api_request(config, 'GET', '/v1/tags/' + identifier)
        if not payload:
            raise ValueError('至少提供一个修改字段')
        return api_request(config, 'PATCH', '/v1/tags/' + identifier, payload)
    if name == 'enote_sync':
        return api_request(config, 'POST', '/v1/sync', {}, timeout=125)
    if name == 'enote_update_todo':
        payload = dict(arguments)
        identifier = payload.pop('id').upper()
        if not re.fullmatch(r'T?[0-9]+', identifier):
            identifier = str(UUID(identifier))
        if not payload:
            raise ValueError('至少提供一个修改字段')
        return api_request(config, 'PATCH', '/v1/todos/' + identifier, payload)
    return api_request(config, 'POST', '/v1/notes' if name == 'enote_create_note' else '/v1/todos', arguments)


def dispatch(message, config):
    if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
        return {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Invalid request'}}
    if 'id' not in message:
        return None
    response = {'jsonrpc': '2.0', 'id': message['id']}
    method, params = message['method'], message.get('params', {})
    if not isinstance(params, dict):
        response['error'] = {'code': -32602, 'message': 'Invalid params'}
        return response
    if method == 'initialize':
        requested = params.get('protocolVersion')
        version = requested if requested in ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25') else '2024-11-05'
        response['result'] = {'protocolVersion': version, 'capabilities': {'tools': {}},
                              'serverInfo': {'name': 'e-note', 'version': '1.1.0'},
                              'instructions': '操作 E note 优先使用这些专用工具，无需在 shell 中连接本地 HTTP。仅按用户要求修改记录。'}
    elif method == 'ping':
        response['result'] = {}
    elif method == 'tools/list':
        response['result'] = {'tools': TOOLS}
    elif method == 'tools/call':
        try:
            result = invoke(params.get('name'), params.get('arguments', {}), config)
            response['result'] = {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}], 'isError': False, 'structuredContent': result}
        except urllib.error.HTTPError as error:
            # Never forward arbitrary HTTP bodies or headers (which can contain credentials).
            response['result'] = failure('E note API 返回 HTTP ' + str(error.code) + ('；目标受保护：待办需已完成或归档，标签需解除绑定，已删除便签需先恢复。' if error.code == 409 else '；请检查目标、参数及 API 设置；新增工具需要新版 E note。'))
        except (OSError, ValueError, KeyError, TypeError) as error:
            message = ('E note 参数或配置不正确。' if isinstance(error, (ValueError, KeyError, TypeError))
                       else '无法连接 E note；请确认应用已运行并开启本地 API。')
            response['result'] = failure(message)
    else:
        response['error'] = {'code': -32601, 'message': 'Method not found'}
    return response


def failure(message):
    return {'content': [{'type': 'text', 'text': message}], 'isError': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home()/'Library/Application Support/ENote/api.json')
    args = parser.parse_args()
    # MCP STDIO uses one JSON-RPC message per line; stdout is protocol-only.
    while True:
        line = sys.stdin.buffer.readline(1024 * 1024 + 1)
        if not line:
            return
        if len(line) > 1024 * 1024:
            return  # Stop an oversized stream without executing any partial request.
        try:
            response = dispatch(json.loads(line), args.config)
        except (ValueError, UnicodeError):
            response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
