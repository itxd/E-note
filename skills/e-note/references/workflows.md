# 云端任务执行协议

本机 API 是唯一入口，账号密码和云端 token 由桌面管理。首先运行 `scripts/e_note.py sync-status`，核对账号；联网工作执行 `sync`，成功后读取 `todos` / `workflows`。未登录可记录本机内容，但不能远程领取任务。

每次流程写入前读取最新状态及 `cursor`，把本次请求的完整 JSON 保存到文件，其中 `requestID` 是新 UUID。调用超时使用同一文件重试，不生成新的执行请求。服务端拒绝过期 cursor 时，重新同步、核对变化，再用新 requestID 表达新的意图。

```bash
python3 scripts/e_note.py sync
python3 scripts/e_note.py workflows
python3 scripts/e_note.py workflow --file /absolute/path/create.json
python3 scripts/e_note.py workflow --id FLOW_UUID --action message --file /absolute/path/message.json
```

创建文件格式：

```json
{"requestID":"本次操作 UUID","cursor":12,"todoID":"已同步的 TODO UUID"}
```

所有后续操作使用返回的 `workflow.id`，关联方案便签使用 `workflow.noteID`；便签的 `linkedTodoID` 指向原 TODO。

| 操作 | JSON 中的额外字段 | 必要条件 |
| --- | --- | --- |
| `message` | `role: user/assistant`, `text` | 真实讨论内容；不伪造用户发言 |
| `plan` | `plan`, `workspace` | 已有用户讨论；方案描述目标、范围、步骤、验证和验收；工作目录为绝对路径 |
| `approve` | `planVersion`, `approvalCode`, `actor` | **用户已明确批准该版本方案**；AI 不替用户批准 |
| `claim` | 无 | 同步完成且已批准；服务器检查 TODO 和方案便签是否又被修改 |
| `heartbeat` | `leaseToken` | 仅持锁执行设备调用；每 20 秒续期；无需 cursor |
| `event` | `leaseToken`, `text` | 记录实际执行过程；无需 cursor |
| `finish` | `leaseToken`, `success`, `result` | 执行进程已结束；无需 cursor；失败也记录实际结果 |
| `accept` | `accepted: true` | 用户验收结果后才调用；原 TODO 未被其他设备改变 |
| `reopen` | `reason` | 重新讨论，废止之前的确认状态 |
| `recover` | `confirmedStopped: true` | 锁已过期，且**用户已确认旧进程停止**；之后重新讨论、重新批准 |

执行锁有效期 90 秒。领取成功后在本机持久化 executionID、leaseToken 和进程状态，再启动 CLI。任何相同 executionID 不启动第二次。续期失败立即终止 CLI；禁止自行抢占或把“网络不可达”当作“原进程已退出”。原设备可在网络恢复后补记最终结果，已被人工恢复的旧锁不再有效。

`finish(success=true)` 进入待验收，**不会直接完成 TODO**。用户确认结果后 `accept` 才会完成关联任务。讨论、方案和结果都写入同一张关联便签。

优先使用项目中的飞书桥接程序承担续期、进程日志、去重和断线结果补记；如果自行实现客户端，须保留这些行为。完整本机/云端接口见项目 `docs/API.md` 和 `docs/CLOUD.md`。
