# E note MCP

让支持 MCP 的 AI 客户端通过本机 E note 操作便签、待办和标签。Python 标准库实现，无需 pip 安装依赖。

## 安装

需要 macOS、Python 3.9+，以及本次代码构建的 E note（本地 API v2）。旧版 v1.0.0 不支持新增的编辑、删除和恢复接口。

1. 运行 E note，在设置中开启本地 API。
2. 在项目目录执行 `python3 scripts/install_mcp.py`。
3. 将输出的 `mcpServers.e-note` 配置合并到 AI 客户端的 MCP 设置，然后重启连接。安装器不修改已有客户端配置。
4. 让 AI 调用 `enote_health`，确认 `apiVersion` 为 2。

安装文件和通用配置保存在 `~/Library/Application Support/ENote/mcp/`。客户端启动安装后的 `e_note_mcp.py`，通过标准输入输出通信。也可直接配置源码脚本的绝对路径；`command` 应使用 Python 的绝对路径。

连接器自行读取 `~/Library/Application Support/ENote/api.json`；不需要把令牌写入 AI 配置。切换账号后操作当前账号。可通过脚本的 `--config /绝对路径/api.json` 指定隔离配置。

## 工具（19 个）

| 对象 | 工具（均以 `enote_` 开头） |
|---|---|
| 便签 | `list_notes`、`get_note`、`create_note`、`update_note`、`delete_note`、`restore_note` |
| 待办 | `list_todos`、`get_todo`、`create_todo`、`update_todo`、`delete_todo` |
| 标签 | `list_tags`、`get_tag`、`create_tag`、`update_tag`、`delete_tag` |
| 服务 | `health`、`sync_status`、`sync` |

便签列表支持 `state: active/archived/deleted/all`，默认 active。便签 `body` 包含首行标题；更新时 `title` 替换首行，`isPinned` 和 `isArchived` 控制置顶和归档。

待办可修改正文、期限、重要程度、完成状态、归档状态及 `tagIDs`。`dueAt` 使用带时区的 ISO 8601 时间，null 清除期限。空 `tagIDs` 清除绑定。

## 可以这样告诉 AI

- “创建一张便签，标题是会议记录，内容是周五讨论发布计划。”
- “创建 E-note 项目标签，给它添加一个明天下午五点到期的重要待办：整理发布说明。”
- “读取 E-note 标签下未完成的待办。”（先读取标签和待办，再按 tagIDs 筛选。）
- “把 T000012 标记完成。”
- “恢复回收站中的会议记录便签。”

删除普通便签会移入回收站；删除待办不可撤销，且只允许删除已完成或已归档项。绑定中的标签需先解除绑定才能删除。执行任务的完成状态应遵循用户验收要求。创建或修改超时后，应先查询现状，避免重复执行。

连接器只开放固定 API 路径，不提供任意文件、命令或网址访问；令牌仅发送到本机 127.0.0.1，不跟随重定向。stdout 仅输出 MCP 协议。MCP 客户端决定如何向用户展示工具调用和确认。

协议参考：[MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[STDIO transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)。
