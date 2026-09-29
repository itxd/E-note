# E note 自动更新与发布

采用 Sparkle 2.10.0（MIT），更新包和 `appcast.xml` 托管在 `itxd/E-note` 的 GitHub Releases。
不需要 Apple 开发者账号、Developer ID 证书或自建服务器。应用保持 ad-hoc 签名，
使用独立的 Ed25519 密钥验证更新来源；这不等同于 Apple 签名或公证，首次安装仍可能被 Gatekeeper 提示。

## 使用行为

- 正式通用构建默认每 24 小时自动检查，Sparkle 管理检查时间和检查会话；唤醒或重新激活时补查到期任务。
- 发现新版本只展示提示，不自动下载、不强制重启。
- 点击“一键更新并重启”授权本次下载、安装、重启；显示下载进度，可在下载阶段取消。
- 解压前必须通过安装包签名验证；清单必须通过签名验证，验证失败没有超时放宽策略。
- 安装前保存所有编辑器并确认落盘，将当前账号加密的 `notes.json` 备份为同目录的 `pre-update-notes.json`。
- 有模态对话框或正在同步时，暂停本次操作并提示稍后重试。保存、备份失败则取消安装。
- 退出阶段再次检查保存结果，失败则取消退出；若安装器已进入等待退出阶段，可在更新窗口重试保存并重启。
- “设置 → 关于”可关闭自动检查；右键边缘小条也可手动检查。
- `release` / `debug` / `run` 为本地构建，不检查线上更新；`universal` 为可分发构建。
- 不实现坏版本启动后的自动回滚；发布前必须人工验证两个版本间的真实升级。

## 依赖与密钥

`bash scripts/fetch_sparkle.sh` 下载固定版本，并校验固定 SHA-256 后解压到忽略提交的 `.build/sparkle/`。
构建时嵌入框架和许可证，保留 Sparkle helper 原有签名与 entitlement；本机应用不启用 Hardened Runtime。

首次配置：

```sh
bash scripts/setup_update_keys.sh
```

密钥初始化需要 Python `cryptography`，发布机可通过 `python3 -m pip install -r scripts/requirements-updates.txt` 安装。
脚本直接生成 Ed25519 密钥到项目内 `.update-signing/ed25519.key`，目录权限 0700、文件权限 0600；
格式为 Sparkle 支持的 Base64 编码 32 字节私钥种子。所有签名命令显式使用 `--ed-key-file`，不访问 macOS 钥匙串。
仅公钥写入 `Info.plist`；整个 `.update-signing/` 目录已加入 Git 忽略，构建脚本不复制它到应用或发布包。
已有密钥会复用，公钥不匹配时拒绝发布，不会自动轮换密钥。

请单独安全备份整个 `.update-signing/` 目录；克隆仓库不会包含私钥。换机器时恢复该目录并设置上述权限。
私钥丢失后，现有用户将无法信任新密钥签署的更新，需手动重新安装。
不要把私钥上传 GitHub、放进发布附件、日志或聊天记录。

## 准备发布（以下命令会编译，须由发布者明确执行）

1. 修改 `Info.plist` 的显示版本号以及严格递增的整数 `CFBundleVersion`。
2. 新建 `docs/releases/v显示版本号.md`，内容作为清单内的更新说明。
3. 执行：

```sh
bash scripts/package_release.sh
```

打包前会从本地私钥推导公钥，并确认与应用公钥匹配。该脚本生成 Universal App、DMG、ZIP、签名后的 `appcast.xml` 和校验和。
清单从 ZIP 中读取应用版本、公钥、系统要求，绑定具体的 `/releases/download/v版本号/` 地址，
不会让检测后正在下载的文件随 `latest` 改变。签名后不得再编辑 XML 或重新压缩 ZIP。

`generate_appcast.py` 会验证安装包与清单的 Ed25519 签名。它不联网、不创建 Release、不 push。
清单只包含当前版本，暂不提供差分包或多系统兼容分支；提高最低 macOS 版本前需扩展历史清单策略。

## 人工验证与发布

先在独立测试账号/测试机验证首次安装，以及旧通用构建到新通用构建的实际升级：
检查取消下载、网络失败、损坏签名、磁盘写入失败、正在编辑、同步期间点击更新、重启后的便签完整性。
本地脚本静态检查不能替代该验证。

人工验证后才能 push。然后人工创建与清单完全相同标签的 GitHub Release（例如 `v1.0.3`），先保持草稿：

- 上传 `E-note-macOS-universal.dmg`、`E-note-macOS-universal.zip`、`appcast.xml`、`SHA256SUMS.txt`、`INSTALL.txt`。
- 确认所有资产完整后，发布为正式且 latest 的 Release；不要先发布空 Release 再慢慢上传文件。
- 更新器固定读取 `https://github.com/itxd/E-note/releases/latest/download/appcast.xml`。
- 发布后检查该地址可用，并用已安装旧版做一次真实升级。无需 GitHub Pages。

首次带更新器的版本为 1.0.3（构建 4）。1.0.2 及更早用户需手动安装一次。
本机源码接入完成并不代表线上更新可用：仍需要构建、人工验证和正式发布。

参考：[Sparkle 文档](https://sparkle-project.org/documentation/)、
[发布更新](https://sparkle-project.org/documentation/publishing/)。
