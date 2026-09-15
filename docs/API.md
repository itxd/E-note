# E note 本地 API v1

作者：韦冬 · 2220285589@qq.com

E note 运行时提供 HTTP API，默认开启，可在 **设置 → API → 允许本机程序和 AI 调用** 关闭。只监听 `127.0.0.1:49178`，不向局域网发布。实现使用系统 socket，显式绑定 IPv4 回环地址。

配置在 `~/Library/Application Support/ENote/api.json`，包含 `baseURL`、`token`，文件权限 0600；永久令牌在同目录的 `api-token`。关闭 API 会移除运行配置，重启后令牌不变。可在设置复制令牌。所有接口（包括健康检查）需要 `Authorization: Bearer <token>`，写入时需要 `Content-Type: application/json`。

请求最大 1 MiB，单连接一个请求，10 秒超时，不支持 chunked、网页跨域或 WebSocket。不跟随 HTTP 重定向。并发写入由应用主线程串行处理。

Codex 或飞书 cc-connect 会话的 shell 若无法访问本地网络，可安装随附的 STDIO MCP 连接器，使用固定的便签/TODO 工具调用同一 API；安装步骤和工具列表见 [README 的 MCP 对接](../README.md#飞书-cc-connect--沙箱环境接入-mcp)。连接器不接收任意 URL 或 shell 命令，不传递令牌给模型，也不需要开放 API 到局域网。

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/v1/health` | 应用与 API 版本 |
| GET | `/v1/notes` | 活跃便签（包含正文与关闭常驻后的 TODOList） |
| POST | `/v1/notes` | 创建普通便签，返回 `note` |
| GET | `/v1/todos` | 返回 `enabled`、`noteID`、`items` |
| POST | `/v1/todos` | 向唯一 TODOList 添加一项或批量添加，返回 `noteID`、`items` |
| GET | `/v1/todos/{id}` | 按编号或 UUID 查询一项，返回 `item` |
| PATCH | `/v1/todos/{id}` | 按编号或 UUID 修改任务内容、分类、优先级、到期或完成状态，返回 `item` |

创建普通便签：

```json
{"title":"会议记录","body":"确定周五发布，先完成回归测试。"}
```

`body` 必填、非空，最多 200000 字符。`title` 可选，最多 40 字符，作为正文首行插入；应用按首行生成显示标题。

新增或修改 TODO：

```json
{"text":"完成回归测试","category":"工作","priority":"high","dueAt":"2026-09-18T17:00:00+08:00"}
```

`text` 新增时必填，最多 10000 字符；`category` 默认“收集箱”，最多 80 字符；`priority` 为 `normal`（默认）或 `high`；`completed` 为布尔值，默认 `false`；`dueAt` 为带时区 ISO 8601 字符串，缺省无到期时间，PATCH 传 `null` 可清除。PATCH 只更新传入字段。

每项任务独立存储，具有不可变 UUID `id`、递增整数 `number` 和显示编号 `code`（如 `T000001`）。单机和云端账号各自分配编号，离线任务首次上传会获得账号编号；UUID 永久不变。已分配的账号编号在修改、完成、排序或重启后不变，删除后不复用；旧版无编号任务首次加载时自动补齐。`id`、`number`、`code` 是只读字段，不能在请求体中设置。

`GET` / `PATCH /v1/todos/{id}` 中的 `{id}` 可使用 `T000001`、`1` 或 UUID。例如：

```http
PATCH /v1/todos/T000001
Content-Type: application/json
Authorization: Bearer <token>

{"text":"完成全部回归测试","category":"工作","priority":"high"}
```

修改后响应保留原编号：

```json
{"item":{"id":"任务的 UUID","number":1,"code":"T000001","text":"完成全部回归测试","category":"工作","priority":"high","completed":false,"dueAt":null}}
```

TODOList 是固定占用第一张 note 位置的独立任务模块，普通 note 中的 `☐` / Markdown 待办仍属于普通文本，不会被 `/v1/todos` 返回或修改。后者传入普通 note 的 UUID 返回 404。

批量添加：

```json
{"items":[{"text":"提交周报","category":"工作"},{"text":"预约体检","category":"生活"}]}
```

一次 1–100 项，先验证所有输入，任何一项无效则整批不写入。不同内容可以相同标题，每个任务都有独立 ID。

临近到期与逾期提醒只针对这些结构化 TODO；默认提前 10 分钟让标签探出，临近到期橙点、逾期红点，不抢焦点或自动展开正文。可在设置中关闭提醒或修改提前时间。普通 note 正文的任务行不触发此提醒。

常驻开关只控制 Deck 中的显示。关闭后仍可通过便签库或 API 管理 TODO；调用不会自动打开常驻开关。启用时 TODOList 始终排在第一位，不能通过拖动、新建普通便签改变这一点。TODOList 本身不提供归档/删除，具体任务可在界面删除。

成功读取/修改返回 200，创建返回 201。错误为 `{"error":"说明"}`，状态码包含 400（参数/JSON）、401（令牌）、403（网页来源）、404（路径/任务）、413（请求过大）、415（内容类型）、431（请求头过大）、500（内部或保存失败）。没有幂等键；创建超时或保存失败后先查询再决定是否重试，避免重复任务。

推荐使用项目附带的 Python 标准库客户端（自动读取令牌，不在命令中暴露令牌）：

```bash
python3 skills/e-note/scripts/e_note.py todo --text '提交周报' --category 工作
python3 skills/e-note/scripts/e_note.py notes
```

配置缺失时先启动应用并检查 API 开关；端口占用会显示在设置中。测试进程可用 `NOTY_DATA_DIR`、`ENOTE_SETTINGS_SUITE`、`ENOTE_API_PORT` 分别隔离数据、设置与端口，不影响正式数据。


## 账号和同步 API

同样使用本机 Bearer token，云端账号令牌不会返回给调用者。云端请求最多等待 120 秒；客户端超时应留出余量。日常离线写入与旧接口兼容，**远程 AI 操作前应显式同步并核对账号**。

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/v1/sync/status` | signedIn、accountID、username、deviceID、cursor、busy、conflicts、lastSync |
| POST | `/v1/sync` | `{}`；上传/拉取/合并，完成后返回状态；有冲突时 409 |
| POST | `/v1/sync/resolve` | `id`、`choice: local/remote/both`；明确选择冲突版本 |
| POST | `/v1/account/login` | server、username、password、可选 certificateSHA256、importOffline |
| POST | `/v1/account/register` | 同 login，另需 registrationCode |
| POST | `/v1/account/logout` | 退出账号并切回独立本机便签 |
| GET | `/v1/workflows` | 先同步，再返回 workflows 与 sync 状态 |
| POST | `/v1/workflows` | requestID、cursor、todoID；创建关联方案便签 |
| POST | `/v1/workflows/{UUID}/{action}` | 讨论、方案、确认、执行及验收，见下表 |

云端流程的写入请求必须保存 `requestID`（UUID）及完整请求体；超时用同一个请求重试。相同 ID 不可用于不同意图。`cursor` 是调用者实际读取和核对过的账号状态，不能猜测；服务端变化会返回 409，重新同步、核对后再决定是否提交新的请求。

| action | 额外字段 | 状态结果 |
| --- | --- | --- |
| message | role(user/assistant)、text | discussing |
| plan | plan、workspace(绝对路径) | awaiting_approval；返回 planVersion、approvalCode |
| approve | planVersion、approvalCode、actor | approved；需要用户真实确认 |
| claim | 无 | running；返回 executionID、deviceID、leaseToken、leaseUntil |
| heartbeat | leaseToken | 续期 90 秒，每 20 秒调用一次 |
| event | leaseToken、text | 添加过程记录 |
| finish | leaseToken、success、result | awaiting_result / failed |
| accept | accepted(true) | 用户验收，完成关联 TODO |
| reopen | reason | discussing，重新讨论方案 |
| recover | confirmedStopped(true) | 只解除已过期且人工确认旧进程停止的锁；interrupted |

`heartbeat/event/finish` 使用持锁令牌，不需 cursor；其他流程操作都先同步并校验 cursor。服务端不自动抢占过期锁。`finish` 可由原持锁设备在断线后补记，但已废止的执行锁会拒绝写入。

普通便签响应增加 `linkedTodoID`、`workflowID`（普通记录为 null）。TODO UUID 用于关联和跨设备操作。完整流程示例与 CLI 生命周期约束见 [Skill 执行协议](../skills/e-note/references/workflows.md)。

## 云端协议

桌面通过 HTTPS 调用独立云端服务。本机 API token 与云端 token 不通用。

- `POST /v1/auth/register`：username、password、deviceID、registrationCode。
- `POST /v1/auth/login`：username、password、deviceID；返回 accountID、username、token。
- `POST /v1/auth/logout`：撤销当前 token。
- `GET /v1/sync`：返回 cursor、entities、workflows、serverTime。
- `POST /v1/sync`：requestID 和 changes；每条 change 包含 id(大写 UUID)、kind(note/todo/tag)、baseRevision、deleted、payload。每批至多 1000 条，原子 CAS，冲突 409 附带 snapshot。
- `/v1/workflows…`：与本机转发的流程协议一致，按账号隔离；设备绑定登录 session。

云端 payload 中时间为 Unix 秒，本机 TODO API 仍使用 ISO 8601。待办 payload 字段为 text、category、priority、completed、dueAt、number；number 由服务器分配。便签 payload 为 title、body、colorName、createdAt、modifiedAt、isPinned、isArchived、deletedAt、linkedTodoID、workflowID。deleted=true 是永久删除的 tombstone，软删除使用 deletedAt。

服务不为浏览器开放 CORS。通用错误还包括 401 登录失效、409 版本或流程状态不符、429 登录限流。部署、密钥和备份见 [云端指南](CLOUD.md)。


## 标签与 TODO 归档

- `GET /v1/tags` 返回 `tags` 数组，按 `modifiedAt` 倒序；旧标签缺少修改时间时排在后面。
- `GET /v1/tags/{uuid}` 读取单条标签完整资料，返回 `tag`。
- `POST /v1/tags` 创建标签，字段为 `name`（必填，最多 80 字符）、`type`（项目 / 版本 / 其他）、`details`（最多 20000 字符）、`link`（最多 2000 字符），返回 `tag`。
- `PATCH /v1/tags/{uuid}` 编辑标签资料，返回 `tag`。
- 创建或修改 TODO 可传 `tagIDs`（已存在标签的 UUID 数组，最多 100 个）及 `archived` 布尔值。
- TODO 查询增加 `tagIDs`、`archived`、`completedAt`、`archivedAt`；完成时间由应用记录，查询列表包含归档任务，调用方按 `archived` 筛选。


标签的 `modifiedAt` 由应用在保存时记录，API 返回 ISO 8601 时间。云端 `tag` 实体同步 name、type、details、link、modifiedAt，TODO 通过 tagIDs 引用标签 UUID。不同字段并发编辑自动合并，同字段冲突在账号设置中处理。

### AI 调用示例

所有接口沿用本机 API 的 Bearer 鉴权。附带客户端自动读取 `api.json`：

```bash
python3 skills/e-note/scripts/e_note.py tags
python3 skills/e-note/scripts/e_note.py tag --id '<标签 UUID>'
python3 skills/e-note/scripts/e_note.py tag-create --name 'zya-V0910' --type 版本 --details '版本目标' --link 'https://example.com'
python3 skills/e-note/scripts/e_note.py tag-update --id '<标签 UUID>' --details '更新后的版本目标'
python3 skills/e-note/scripts/e_note.py update --id T000008 --tag-id '<标签 UUID>'
```

MCP 提供 `enote_list_tags`、`enote_get_tag`、`enote_create_tag`、`enote_update_tag`；`enote_create_todo` 和 `enote_update_todo` 支持 `tagIDs` 数组。更新已有 MCP 进程后需重新连接，才能发现新工具。
