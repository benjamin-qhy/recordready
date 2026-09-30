# ADR-0002：Windows 录制宿主与签名增量升级

日期：2026-09-30。关联 [Issue #20](https://github.com/benjamin-qhy/recordready/issues/20)。用户明确授权参照 haiqiai 增加 Windows 版本、应用内更新、实机测试及服务器发布。

RecordReady 既有 Tauri 窗口调用 Swift/AppKit/ScreenCaptureKit。Windows 分支原先直接返回 unsupported_platform。采用独立 Electron Windows 宿主，复用现有 React 界面和动作接口；macOS 继续使用 Tauri/Swift。这样可以复用 haiqiai 已验证的 Electron NSIS 更新协议，同时增加实际可用的 Windows 采集。代价是 Windows 安装包较大、需要维护两个宿主，且 Chromium 采集不等同于原计划的全部原生能力验收。

Windows 由受隔离的采集 renderer 持有屏幕、相机和麦克风流；输出画布按所选显示器及区域裁切，显式合成相机预览。应用辅助窗口在会话忙碌时通过内容保护排除。每次录制重建画布，竖向输出高度超过 2160 时使用 CPU 画布以规避验收 GPU 的无输出问题，当前有明显性能限制。MediaRecorder 生成 H.264/AAC MP4，主进程顺序落盘到会话独立目录；编码器有数据后才标记开始；停止后刷盘并检查 MP4 容器，成功文件才成为正式 MP4，失败流保留 partial。成片发布使用排他硬链接，文件系统不支持时使用排他复制，禁止覆盖同名文件。FFmpeg 仅用于开发验收，不随应用分发。

首轮安装为 NSIS 当前用户安装，应用身份固定为 com.recordready.desktop.windows。Windows 自有 Ed25519 密钥独立于 macOS 和 haiqiai；签名认证完整清单中的平台、架构、版本、安装文件名、大小和 SHA-512。通过 electron-updater 6.8.10 的自定义 Provider 把验证后的清单交给成熟分块下载器。复用旧安装器缓存，通过 HTTPS Range 下载差异，缺少缓存、映射或校验失败时回退完整包。重建及缓存命中结果仍重新校验整体哈希。

下载和安装均由用户操作。安装前检查会话状态，确认对话框后再次检查，最后校验安装器；准备、倒计时、启动、录制、暂停、保存时拒绝安装。交接阶段锁定新录制，独立安装助手先取得父进程句柄并回执，再等待应用退出、运行安装器并重启。安装失败写日志，不把失败当成功。没有自动下载、退出时自动安装或后台强制重启。

Windows 更新源固定为 https://recordready.qiushui.me/updates/windows/x64/release.json。发布复用 /srv/recordready/deploy.lock，通过可信 SSH 上传、逐文件核对 SHA-256、保留不可变归档、生成完整站点快照，最后切换 site 符号链接。保留原 macOS 页面、DMG 和 appcast；以后 macOS 发布也保留 Windows 更新目录和下载入口。未引入另一产品目录或修改服务器共享配置。

本机是 Windows 10 22H2 x64。该实现不关闭 #5 和 #7：Windows 11 x64、物理音画同步 ≤200ms、DPI/多显示器完整矩阵、硬件编码保证仍需实测。Windows 当前目标采样 30fps，采用可变帧率封装，不宣称固定逐帧间隔；不提供 macOS 原生美颜。现有 ADR-0001 的 macOS 架构及发布信任链继续有效。本记录不表示服务器部署或 HTTPS 实机升级已经完成。
