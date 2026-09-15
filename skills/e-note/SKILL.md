---
name: e-note
description: 在本机 E note 应用中创建便签、添加分类 TODO、查看待办、修改内容、云端同步，以及讨论和执行关联任务方案。用于用户明确希望把信息记录到 E note、常驻 TODOList 或通过其本地 API 操作便签时。
---

# E note

若工具列表中有 `enote` MCP，日常便签和 TODO 操作优先使用它：`enote_list_todos`、`enote_list_notes`、`enote_create_note`、`enote_create_todo`、`enote_update_todo`、`enote_health`、`enote_sync_status`、`enote_sync`。它由本机宿主连接 E note，适用于 shell 无法访问本地网络的 Codex/飞书会话；无需读取或复制 API 令牌。更新工具的 `id` 接受编号或 UUID，`completed` 控制完成状态，`dueAt: null` 清除期限。下述任务识别、重试、同步和人工验收规则同样适用。

使用随附的 `scripts/e_note.py` 调用正在运行的 E note。脚本从 `~/Library/Application Support/ENote/api.json` 读取本机地址及访问令牌，不需要手动复制令牌。可用 `--config /path/api.json` 覆盖配置位置。

在 skill 所在目录执行，或使用脚本的绝对路径：

```bash
python3 scripts/e_note.py health
python3 scripts/e_note.py note --title '会议记录' --body '确定周五发布，先完成回归测试。'
python3 scripts/e_note.py todo --text '完成回归测试' --category 工作 --priority high --due-at '2026-09-18T17:00:00+08:00'
python3 scripts/e_note.py todos
python3 scripts/e_note.py update --id T000001 --text '完成全部回归测试' --priority high
python3 scripts/e_note.py complete --id T000001
```

- 普通记录创建 note；可执行事项加入唯一的 TODOList，不把解释性长文或会议全文当成任务。
- 仅在用户提供或上下文明确时填写分类、优先级和到期时间；默认分类为“收集箱”、优先级普通、无到期时间。日期需要时区，不能猜测用户未给出的期限。
- 批量任务使用 `batch --file /absolute/path/items.json`，文件格式为 `{"items":[{"text":"任务内容","category":"工作"}]}`，一次最多 100 项。
- 每条 TODO 有不可变 UUID（`id`）和持久化编号（`number`、`code`，例如 `T000001`）。单机编号和云端账号编号各自递增；离线新任务首次上传时由服务器分配账号内编号，显示编号可能改变，UUID 不变。跨设备操作先同步并使用 UUID；已经分配的账号编号不再复用。`update` / `complete` 可用编号或 UUID；优先使用用户给出的编号，不按当前列表下标猜测。
- 修改或标记完成前根据返回的编号和文本匹配目标；标题相同且无法确定时澄清目标。
- TODOList 的任务是独立的结构化数据。普通 note 正文里的复选框不属于此 API 的 TODO，不能使用普通便签 ID 调用任务修改接口。
- 调用成功后用返回的数据简短确认已保存的便签或任务。不要展示令牌，也不要直接修改加密的 notes.json 或 note.key。
- 配置缺失或连接失败时，说明需启动 E note，并在“设置 → API”开启调用。不要改为写其他应用。常驻 TODOList 开关关闭时仍能添加任务，但不会替用户打开常驻开关。
- shell 报 `Operation not permitted` 时，先用可用的 `enote_health` / `enote_list_todos` MCP 工具检查；不能仅凭 shell 网络受限断言应用未启动。MCP 未安装时说明需要接入本机 E note MCP，不自动修改宿主沙箱权限。
- 创建请求超时或返回保存失败时，先用 `notes` / `todos` 查询是否已写入，不要自动重复提交；这些创建接口没有幂等键。

账号已登录时，在读取远程任务或执行修改前先运行 `python3 scripts/e_note.py sync`，并确认 `sync-status` 的账号与用户目标一致。冲突或网络失败时保留本机记录，暂停远程执行，不宣称云端已更新。

用户要讨论、制定方案或让 AI 执行 TODO 时，阅读 [云端任务执行协议](references/workflows.md)。必须先澄清任务并形成关联方案便签，取得用户对具体版本方案的确认，然后领取服务器执行锁；执行结果写回后等待用户验收，不能由 AI 自行完成验收。

完整 API 协议随 E note 项目提供在 `docs/API.md`。日常任务使用上述脚本即可。
