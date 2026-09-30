# RecordReady Windows

Windows x64 实现和内测发布入口，跟踪 [Issue #20](https://github.com/benjamin-qhy/recordready/issues/20)。当前发布版本为 0.1.0-windows.6。架构与支持边界见 [ADR-0002](../../docs/adr/0002-windows-electron-signed-updates.md)。

## 构建

需要 Node.js、pnpm 11、Visual Studio 2022 C++ Build Tools 和 Windows SDK。先从仓库根目录安装已有前端的锁定依赖，再安装 Windows 宿主依赖。此目录的 pnpm 锁文件固定 Electron 44.3.0、electron-builder 26.15.3、electron-updater 6.8.10；前端仍以原 package-lock.json 为准。

```powershell
npm ci --prefix desktop
pnpm --dir desktop/windows install --frozen-lockfile
./desktop/windows/build-native.ps1
node desktop/windows/release.mjs init
node desktop/windows/build.mjs
```

`init` 首次建立 `%USERPROFILE%/.recordready-release/windows-keys`，移除继承权限并只授权当前用户；以后复用并核对密钥，不会静默替换残缺密钥。私钥不进入仓库或分发包，需安全备份。公钥和 HTTPS 更新源生成到被忽略的 `resources/update-config.json`。

在本目录生成 NSIS：

```powershell
node node_modules/electron-builder/cli.js --config electron-builder.json --win nsis --x64 --publish never
```

版本由本目录 package.json 管理，与 macOS 版本分开递增。包、sidecar blockmap 和签名清单在最终打包后生成；现有版本不可重用。安装包没有 Authenticode 发布者证书，Ed25519 更新签名不能替代 Windows 发布者身份。

```powershell
node release.mjs sign 0.1.0-windows.6
node deploy.mjs 0.1.0-windows.6 --prepare-only
```

## 验证

仓库根目录执行：

```powershell
node --test desktop/windows/tests/*.test.mjs
node desktop/windows/test-network.mjs
python scripts/release/deploy-windows-remote.test.py
python scripts/release/deploy-remote.test.py
```

网络回归实际运行 Electron HTTP 下载器，覆盖增量、缓存缺失/损坏、映射缺失、Range 不可用、坏签名、坏载荷和旧版本拒绝。测试 fixture 不执行安装器。Linux 原子切换和 POSIX 权限用例在 Windows 明确跳过，部署前在 Linux 临时测试目录运行同一测试。

`RECORDREADY_TEST_DATA` 可为人工验收隔离设置，`RECORDREADY_TEST_CONTROL=1` 显式启用仅回环地址、随机令牌保护的应用动作验收接口。默认安装运行不启用该接口。控制文件只留在隔离数据根；不要把它上传或作为线上服务开放。

`test-recording.mjs <隔离数据根>` 对已运行的实际安装包进行设备采集、双文件/静音录制、暂停继续和保存；`test-resolutions.mjs` 检查当前固定 installed-data 副本的分辨率、录制中退出保护、无效目录和缺失显示器。它们会录制当前桌面并修改隔离测试配置，原始录像仅留本机。`verify-recordings.mjs` 对实录报告中的文件完整解码，另核查音轨、像素与原始时间戳；仅文件存在不算通过。`test-handoff.mjs <版本>` 用签名 NSIS 包验证隔离安装副本的原生助手交接、重启和数据保留，不改变 HTTPS 更新源。

## 发布

发布目标限定为 `root@39.96.16.242:/srv/recordready`。设置环境变量为已有 SSH 私钥路径和已验证的 known_hosts 路径；不跳过主机认证或降级公网 HTTP。

```powershell
$env:RECORDREADY_SSH_IDENTITY = '本机已有私钥的绝对路径'
$env:RECORDREADY_SSH_KNOWN_HOSTS = '可信 known_hosts 的绝对路径'
node desktop/windows/deploy.mjs 0.1.0-windows.6
```

先发布并安装首个版本，再发布递增版，以真实 HTTPS 源完成应用内下载、延后、忙碌保护、确认安装和自动重启验证。下载页为 `/windows/`，归档为 `/releases/windows/<version>/`。更新目录包含完整包与 blockmap 链接，供旧缓存差分和全量回退。

发布脚本保留 macOS 内容，逐文件验哈希后切换站点；不可变归档已到位但切换失败时，同一字节内容可重新上传重试，不能改包复用版本。`.6` 的一次性 CI 工作流从 GitHub Release 下载本机签名的不可变产物，核对来源提交、签名和哈希后部署，并重新下载公网安装包核对哈希。更新私钥不传入 CI；临时 SSH 凭据仅供该次工作流使用。4K 竖屏在验收 GPU 上需 CPU 画布，帧率偏低；当前不承诺 4K 30fps。

## 源码入口

- `main.mjs`：窗口、命令边界、会话状态、退出保护和设备配置。
- `engine.js`：真实采集、画布合成、MP4 编码及有界写入队列。
- `recording-files.mjs`：排他创建、顺序写入、部分失败保留与成片发布。
- `updater.mjs` / `signed-provider.mjs`：签名更新、取消意图、安装确认与门禁。
- `update-runner.cc`：独立 NSIS 安装和重启助手，参考 haiqiai 的实现并加入启动回执。
- `release.mjs` / `deploy.mjs`：密钥、签名清单、blockmap 和独立服务器发布。

实际完成项和未测项见 [Windows 验收记录](../../docs/implementation/2026-09-30-windows-validation.md)。本轮构建和实录证据暂留 `evidence/`、`.validation/`、`release/`；它们均不提交 Git，等待线上验收及用户确认后再清理。
