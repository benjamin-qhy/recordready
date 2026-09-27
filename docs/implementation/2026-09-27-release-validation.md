# 发布升级实施与验收记录

规格追踪：https://github.com/benjamin-qhy/recordready/issues/18

## 已实现的边界

原生 `RecordReadyUpdater` 直接驱动 Sparkle。启动两秒后及每四小时只查询信息；设置页、独立更新面板和应用菜单提供入口。下载、重启分别需要用户操作，安装确认默认“稍后”。`UpdateInstallationGate` 在主线程预留安装，阻止新录制与设置变更；录制准备、倒计时、开始、录制、暂停、保存和未知阶段拒绝预留。普通退出取消尚未授权安装的更新，错误恢复撤销退出权限。

完整 ZIP 和增量包都由独立 Ed25519 密钥签名，应用包 ad-hoc 签名；固定域名 `recordready.qiushui.me`。密钥位于用户私有目录，不入 Git。首次安装版必须手动安装，旧版没有升级器。分发脚本只构建，部署脚本单独操作服务器。

## 当前验证证据

- 安装门禁测试先失败于可空闲安装行为，再实现通过；覆盖全部忙碌/未知状态、互斥及恢复。
- 原生更新集成测试覆盖安装期间录制请求拒绝、错误清锁、完整包回退清空下载计数、普通退出取消安装。
- 审查发现取消检查残留下载意图；回归测试先失败于 `Cancellation must revoke download consent`，修复后通过，另覆盖未发现更新及 teardown。
- 前端 6 项测试通过，构建通过；lint 保留原有 UI 组件 fast-refresh 警告。
- 原生录制回归脚本通过（生命周期、取消、静音 MP4、编码帧率、失败注入、部分保存等）；既有 AVSampleBufferDisplayLayer API 弃用警告仍存在。
- Rust 单元测试 3 项通过。
- 发布模型与页面测试、远端原子发布测试已执行；最终数量以本次测试输出为准。
- Swift/Rust 编译和浏览器开发构建更新面板排版已检查。

## 初次执行时的阻塞（已解除）

初次执行尚未完成公网部署和真实升级。当时记录中的 SSH 身份 `~/.ssh/id_ed25519` 在执行环境不存在，且服务器尚未在 known_hosts 中得到信任；已请求可用连接配置，未绕过主机校验。

不能将单元测试、包签名和离线增量还原成功等同于完成真实应用内升级，也不能承诺升级后不需重新授予录制权限。

## 固定发布产物

| 版本 / 构建 | DMG | ZIP | 增量包 |
| --- | ---: | ---: | ---: |
| 0.1.0-beta.1 / 10001 | 5,187,694 B | 4,773,946 B | 无基线 |
| 0.1.0-beta.2 / 10002 | 5,187,707 B | 4,773,947 B | 10001 → 10002：2,582 B |

两个发布构建均通过最终应用 `codesign --verify --deep --strict`、完整 ZIP 还原验签、DMG 校验和及 Sparkle Ed25519 验签。增量已应用到 beta.1 原始 ZIP 解出的应用，还原结果和代码签名通过。另以真实产物验证 Ed25519：原始 ZIP/delta 被接受，翻转一个字节后被拒绝。beta.2 DMG 已只读挂载，内部应用签名和构建号 10002 已核对。

此次两版功能相同，增量仅用于验证发布机制，不能据此承诺后续更新的压缩比。两个发布记录均如实标记工作区构建 `workingTree: true`，不宣称纯提交可复现构建。

保留的固定应用分别位于：

- `~/.recordready-release/builds/0.1.0-beta.1-nYAtuE/RecordReady.app`
- `~/.recordready-release/builds/0.1.0-beta.2-UEWdZr/RecordReady.app`

beta.1 已通过真实桌面启动，设置页显示 `0.1.0-beta.1 (10001)`，菜单“检查更新…”打开独立更新面板，公网未部署时展示可重试错误。测试实例已通过正常退出确认关闭。原有麦克风权限不足提示出现，本轮未授予/修改系统权限，也未将此启动验证当作录制回归成功。

下载站已生成并在本地浏览器查看中英文页面，下载 URL 指向正式域名；正式域名上的文件尚未上传。公网 DNS 经 Google DNS 查询确认为 `39.96.16.242`；HTTPS 校验失败原因是证书主机名不匹配，未关闭证书校验。

发布工具最终测试：11 项 Bun 测试（53 个断言）、5 项远端发布 Python 测试通过。覆盖失败恢复命令和新站点快照替换，支持恢复中断的本地目录/清单发布且不重写归档。


## 线上部署与真实升级（2026-09-27）

用户提供连接方式后，使用临时 SSH 复用会话完成部署；密码未写入仓库、脚本或文件。连接结束后关闭复用会话。站点独立部署于 `/srv/recordready`，Nginx 配置为 `/etc/nginx/conf.d/recordready.conf`。

- HTTPS 下载页 `https://recordready.qiushui.me/` 正常，证书覆盖域名、到期日 2026-12-26，并接入现有 Certbot 续期定时器及 Nginx reload hook。
- 线上 appcast 与本地完全一致，Cache-Control 为 `no-cache, no-store, must-revalidate`。两个版本的 DMG、ZIP 和 beta.2 delta 经 HTTPS 下载后，长度与 SHA-256 均匹配。
- 实际增量升级：beta.1 自动发现 beta.2，点击下载后只请求 2,582 B delta；“稍后”保留原版，确认安装后 PID 82732 → 82815，版本成为 beta.2 / 10002，严格代码签名通过。
- 实际完整包回退：仅在单独测试副本增加资源文件并重新 ad-hoc 签名，造成基线不匹配；客户端先请求 delta，再自动请求 4,773,947 B ZIP。确认后 PID 82982 → 83165，版本为 beta.2 / 10002，严格签名通过，测试资源文件被完整新版替换。发布原始包和服务器归档未修改。
- 两次升级前后录制配置、美颜与提词等已存在设置序列化后的 SHA-256 都为 `3b72047930c2f5571fa90931bb6d01b86af41cbd9829a0fe7b4439f4392f202a`。窗口位置等正常交互会变化的项目不算入此比较。
- Nginx 配置检查通过，原海奇AI下载页仍返回 HTTP 200。
- 实际部署发现本机私有暂存目录权限可能阻止 Nginx 访问，补充了验证后公共目录 0755/文件 0644 的归一化；先观察新增回归失败，再修复，6 项 Python 部署测试通过。私钥从未进入公共目录。

本机证据保留在 `~/.recordready-release/evidence/online-upgrade/`，包括 `delta-result.json`、`fallback-result.json`、设置比较快照、线上页面和升级后截图。两个验收副本在 `~/Applications/RecordReady-Validation/` 与 `~/Applications/RecordReady-Fallback-Validation/`；测试进程已正常退出。

### 仍保留的验证边界

此 Mac 原有麦克风授权不可用，启动前后均显示权限提示；本轮未改变 TCC 授权，未验证真实录制及权限跨版本迁移。忙碌安装门禁通过原生自动化测试，未用一段真实录制验证。未进行异机首次安装和全 macOS 13+ 版本矩阵验收。不能因此声称升级后权限永久不变，或所有用户都可无提示首次启动。

证书续期补充验证：`certbot renew --dry-run --no-random-sleep-on-renew --cert-name recordready.qiushui.me` 成功，确认 ACME webroot 续期链路可用。客户端请求摘要保存在本机 `requests.json`，已去掉访问者地址。
