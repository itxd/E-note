# 当前验证记录

## v1.0 下载包发布验证（2026-09-15）

- `./scripts/package_release.sh` 通过：生成包含 `x86_64` 和 `arm64` 的 App、DMG、ZIP、安装说明和 SHA-256 校验文件。
- DMG 校验、只读挂载检查、包内 `codesign --verify --deep --strict` 和 ZIP 完整性检查通过；安装盘包含指向 `/Applications` 的快捷方式和 MIT 许可。
- 从 DMG 复制 App 到隔离目录，在 Intel Mac 上使用独立数据目录、偏好域和端口启动，真实 `/v1/health` 返回 200。Apple 芯片版本已交叉编译，尚未在 Apple 芯片实机运行。
- `./Tests/run.sh`、`Tests/test_cloud.py`（7 项）、`Tests/test_sync.py`、`Tests/test_storage_failure.py`、`Tests/test_bridge_runner.py`（5 项）、`Tests/test_mcp.py`（7 项）全部通过。
- 修正两处测试不稳定因素：标签时间戳在 Unix / Foundation 时间基准转换后按微秒容差比较；续期失败测试等待子进程初始化后再触发终止。
- 候选源码基础凭据扫描仅命中测试密码；`.ssh`、私钥、令牌和运行数据不在 Git 跟踪列表。
- 当前使用 ad-hoc 临时签名，没有 Apple Developer ID 签名或公证；首次打开说明随下载包提供。本轮未重新执行生产服务器测试或飞书手机端全流程验收。

## 既有验证记录

验证环境：macOS Intel 原生 Swift 应用；云端 Ubuntu 26.04 / Python 3 / SQLite；2026-09-14。

| 验证 | 当前证据 |
| --- | --- |
| 本机基础功能 | `Tests/run.sh` 通过：加密、编号、编辑器切换、提醒、API 验证、并发与重启 |
| 云端事务 | `Tests/test_cloud.py` 6 项通过：账号隔离、批量 CAS、编号分配、幂等请求、唯一执行锁、人工确认、过期锁和备份恢复 |
| 两个原生客户端 | `Tests/test_sync.py` 通过：普通便签/TODO 互传、逐字段合并、同字段冲突、两份保留、账号切换、断线补传 |
| 编辑器账号隔离 | 原生测试验证切换前保存、旧回调不能写另一账号或再次登录的旧账号 |
| 同步中断恢复 | 注入实际加密恢复日志，重启原生宿主，恢复并同步到第二客户端 |
| 桥接执行流程 | 测试消息经过真实桥接解析、本机 API、云端、真实子进程调用测试 CLI；确认前不写文件，验收后才完成 TODO；断网结果补记不重跑 |
| 执行监控与结果通知 | `Tests/test_bridge_runner.py` 5 项通过：网络续期卡死仍提前停止、忽略 SIGTERM 的 CLI 被强制结束、过迟的首次确认不启动 CLI、正常续期继续执行、通知与完成状态原子保存并去重 |
| 真实 Codex | 本机 Codex 只读非交互返回验证通过；workspace-write 在隔离目录创建文件并读取验证通过 |
| Kimi 接入 | 本机版本拒绝 `--plan` 与 `-p` 并用；已改为只读 agent-file（Read/Grep/Glob）。真实请求被现有账号周额度限制拒绝，未声称 Kimi 成功执行 |
| 生产 HTTPS | `Tests/test_deployed.py` 通过：原生客户端拒绝错误指纹、接受正确证书、注册/登录/同步/退出/重登；未完成 TLS 握手的连接不阻塞其他客户端；使用临时账号并在测试后删除 |
| 损坏数据保护 | `Tests/test_storage_failure.py` 通过：JSON、密钥、密文损坏时，启动及写入尝试不改变原始文件 |
| Skill | quick_validate 通过；实际客户端 sync-status、sync、workflow、workflows 命令通过 |
| MCP 与飞书 Codex 的本地访问 | `Tests/test_mcp.py` 6 项通过：STDIO 握手、鉴权、中文读写、固定编号修改、拒绝非法参数/外部主机/重定向；已安装到本机 Codex，真实 `workspace-write` 沙箱会话成功调用 `enote_health` 和 `enote_list_todos`，读取 5 条现有 TODO，未修改数据 |
| 应用产物 | `./build.sh release` 与 `codesign --verify --deep --strict` 通过；证书配置与资源一致 |
| 视觉 | 原生账号页面渲染并检查，见 `docs/images/account.png`；原有 TODO 浅色/深色截图回归 |
| 飞书 SDK | 已安装官方 lark-oapi，接收事件和发送消息的构造接口通过验证 |
| 飞书真实手机收发 | **尚未完成 E note 全流程实机验证**：已提供应用凭据，并找到使用同一应用的 cc-connect / codex-bot；E note 专用桥接尚未绑定用户和账号或启用 |

服务器 `enote-cloud.service` 已运行，监听 HTTPS 8443，启用开机启动。部署脚本、证书校验和备份脚本随项目提供。发布至 Git 远端不属于本次操作。

桥接运行环境已安装到本机 `~/Library/Application Support/ENote/bridge-runtime`，代码与项目一致；需要完成 `~/Library/Application Support/ENote/bridge.json` 配置后才能启用。完整目标仍包含飞书实机联调，因此当前不能把整个长任务标记为完成。

本机启用检查：已通过 macOS 标准退出事件关闭旧版，并打开 release 应用；真实本机 `/v1/sync/status` 返回 200，当前为未登录的单机模式。E note 专用桥接的私有配置仍为模板，尚未启用；用户提供的飞书凭据已存在于原有 cc-connect 配置中，未在项目或本文保存密钥。

后续扩大进程检查范围，已找到常驻 cc-connect 的 codex-bot，配置的 App ID 与用户提供的一致，日志记录过飞书长连接成功。此前按 Feishu/Lark 名称检查漏掉了该进程。针对其 Codex 会话被归档导致的恢复错误，已执行 CLI 的 unarchive 命令并收到成功返回；飞书重发后的实际恢复仍待验证。未另外启动同一应用的 E note 长连接入口，避免与现有入口并行消费事件。

用户随后确认飞书 Codex 已恢复回复，但 shell 访问本机 API 报 `Operation not permitted`。本机直接健康检查返回 200；已为 Codex 配置 E note STDIO MCP，让模型通过专用工具访问 API，保留原有沙箱设置。修复后的真实 Codex 工具调用已通过，手机飞书端重发读取请求仍待用户验证；该验证不代替专用工作流的完整实机验收。
