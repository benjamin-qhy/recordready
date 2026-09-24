# macOS 原生录制路径调查

调查日期：2026-09-24。关联：[macOS 原生录制路径：哪些 API 与版本约束有官方依据？](https://github.com/benjamin-qhy/recordready/issues/2)。这是文档研究，不是原生实验；没有生成样片、验证硬件或确认最终支持矩阵。

## 结论

macOS 13+ 存在与方案匹配的公开 API 路径：ScreenCaptureKit 提供过滤后的屏幕帧，AVFoundation 提供摄像头及单路麦克风，两套 AVAssetWriter 分别保存视频，共享转换后的时间基准。官方能力足以进入原生实验，但不证明浮窗组合、双编码吞吐或 30 分钟同步已达标。建议以 SDR、H.264/AAC、MP4 为首个实验候选，格式和性能上限保留待定。

## 能力与证据矩阵

| 问题 | 官方依据与已知边界 | 对实验的含义 |
|---|---|---|
| 排除自身浮窗 | `SCContentFilter(display:excludingApplications:exceptingWindows:)` 可排除应用；WWDC22 展示按 bundle ID 找到待排除应用。见 [过滤器](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:))、[WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/)。 | 优先排除本应用整体，例外窗口列表为空；所有提词、预览、控制条窗口均属于排除集合。创建新浮窗、原生子视图与系统弹窗仍需逐项录屏检查。不以透明度或窗口保密属性代替采集过滤。 |
| 区域与输出尺寸 | `sourceRect` 指定源区域；`width/height` 控制输出。官方样例使用显示缩放，并读取 `contentRect`、`contentScale`、`scaleFactor` 等帧附件。见 [sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)、[捕获样例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)。 | 框的 CSS 坐标、AppKit 点、显示器坐标、输出像素必须分别建模；不能把窗口宽高直接作为编码尺寸。验证 Retina、非 Retina、负坐标外接屏及缩放。跨屏选区是否第一期允许需另作产品决策；不能假设一个 display filter 自动跨屏。 |
| 透明与点击穿透 | Tauri 的透明背景在 macOS 要求 `macos-private-api`，官方明确说明该选择不能被 App Store 接受；半透明 windowEffects 不是同一效果。见 [Tauri 配置](https://v2.tauri.app/reference/config/#windowconfig)。AppKit 的 [ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) 是窗口级行为。 | 原生窗口透明、WebView 背景透明、鼠标命中是三个问题。建议实验采用穿透边框窗口与可交互控件窗口分离，或明确原生命中逻辑。签名公证分发与 App Store 是不同渠道，后续需确认渠道；本研究不判定私有 API 一定可公证。 |
| 摄像头预览 | [AVCaptureVideoPreviewLayer](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer) 可显示采集会话视频，支持独立的显示填充方式。 | 候选为 NSView/CALayer 原生预览；React 只传布局。移动、铺满、镜像只作用于预览连接或 layer，不改送往 writer 的源帧。Tauri/WebView 与原生视图的层级、裁剪、焦点和拖动必须用最小壳验证；官方原生 API 不等于已有 Tauri 集成。 |
| 摄像头与单麦克风 | [AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession) 连接设备输入和输出；`startRunning` 会阻塞，应在串行后台队列运行。 | 一次打开麦克风，通过 audio data output 回调向两个 writer 分发相同采样序列；摄像头通过 video data output 与预览共用会话。此分发结构是工程建议，不是系统自动生成双文件。分别维护有界队列、输入和失败状态。 |
| 双文件 | [AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter) 每个实例写一个文件，可写 QuickTime/MPEG-4、交错音视频并重编码。 | 两个 writer 各有自己的视频和音频输入。对共享采样保留正确生命周期，禁止一个分支修改另一个仍使用的 buffer；若重定时需要修改，使用适当副本。单采集不意味着单次编码。 |
| 共同时间基准 | [SCStream.synchronizationClock](https://developer.apple.com/documentation/screencapturekit/scstream/synchronizationclock)、[AVCaptureSession.synchronizationClock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock) 提供输出时间基准；[CMSyncConvertTime](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:)) 可转换时钟并补偿测得的时钟漂移。 | 读取采样 PTS，以实际时钟转换到 host clock，使用同一会话起点。不能用回调到达时间或两个 start 调用时间替代采样时间。时钟缺失/转换无效须中止准备或明确失败。系统时钟转换不保证设备链路延迟为零。 |
| 起止与封装 | [startSession(atSourceTime:)](https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:)) 定义源时间到文件时间的映射，晚到轨可通过 empty edit 保持同步；说明中特别以 QuickTime 格式举例。 | 两个 writer 用同一源起点；定义起点前丢弃、音频跨界裁切、晚到视频以及统一结束规则。MP4 的实际时间线与播放器行为必须测量，不把 MOV 描述直接当 MP4 保证。等待两个 writer 完成再报告结果。 |
| 编码与性能 | [canApply](https://developer.apple.com/documentation/avfoundation/avassetwriter/canapply(outputsettings:formediatype:)) 检查格式设置；[VideoToolbox 编码器枚举](https://developer.apple.com/documentation/videotoolbox/vtcopyvideoencoderlist(_:_:)) 及 [编码器属性](https://developer.apple.com/documentation/videotoolbox/video-encoder-list-keys) 可查看硬件加速与实例限制。 | H.264/AAC MP4 是待测首选，非已定合同。运行时校验尺寸、帧率、像素格式与并发实例；Intel 和 Apple Silicon 分别测双编码负载。不能依据硬件解码支持推断硬件编码支持。 |

## 最低版本与架构

直接检查 Apple 文档的 DocC 元数据后，macOS 引入版本如下（链接为官方机器可读证据，避免混淆页面上其他平台的 Beta 标志）：

- [SCStream](https://developer.apple.com/tutorials/data/documentation/screencapturekit/scstream.json) 和 [sourceRect](https://developer.apple.com/tutorials/data/documentation/screencapturekit/scstreamconfiguration/sourcerect.json)：12.3。
- [SCStream.synchronizationClock](https://developer.apple.com/tutorials/data/documentation/screencapturekit/scstream/synchronizationclock.json)：13.0；[AVCaptureSession.synchronizationClock](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturesession/synchronizationclock.json)：12.3。
- [captureMicrophone](https://developer.apple.com/tutorials/data/documentation/screencapturekit/scstreamconfiguration/capturemicrophone.json) 与 [SCRecordingOutput](https://developer.apple.com/tutorials/data/documentation/screencapturekit/screcordingoutput.json)：15.0。因此 13+ 基线不能直接依赖这两个便利接口。[WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/) 介绍了新增麦克风输出和直写文件功能，但并未解决本项目摄像头独立文件需求。

因此 macOS 13 作为候选最低版本有 API 依据。Tauri 可构建同时支持 Intel 和 Apple Silicon 的 [Universal App](https://v2.tauri.app/distribute/app-store/#build)；这只证明构建目标存在，不证明所有设备组合及编码负载都能通过。原生桥接和依赖也须各自包含 x86_64/arm64。实验应在真实 Intel 与 Apple Silicon 上分别运行；没有 Intel 设备时明确保留未验证状态，不以 Rosetta 代替硬件能力验收。

## 最小原生实验建议（待后续票实施）

1. **可观测最小链路**：固定一个显示器区域、摄像头与麦克风；两个 writer，输出实际尺寸、格式、采样时钟、首尾 PTS、丢帧、队列深度、峰值内存与逐文件状态。先跑 30 秒、连续三次，再跑 30 分钟。不开系统声音。
2. **排除与交互**：在录制区域内放醒目标记的提词、边框、预览、工具条和设置浮层；录制中创建/移动/隐藏/显示窗口，切换前台应用。肉眼及抽帧确认所有本应用内容均不入屏幕文件，下层画面完整。透明区域可操作下层应用，按钮和拖动区可操作。
3. **坐标与预览**：用带像素标尺的测试画面验证四边、竖屏和自定义尺寸；不同 DPI 屏幕间移动。原生预览可铺满/小窗/拖动，摄像头文件画幅和镜像不被预览修改，屏幕文件不含预览。
4. **同步证据**：开始和接近 30 分钟结束时各产生可见可闻同步事件；比较两路视频和音频首尾偏差。保留原始样片、测量步骤、PTS 日志和测量误差；目标沿用方案的 200ms。相同音频数据也需验证封装后的播放时间，不只比较回调日志。
5. **平台边界**：macOS 13 实机与较新系统、Intel 与 Apple Silicon 分开记录；权限允许/拒绝、摄像头关闭、外接设备、停止封装均覆盖。明确哪些环境缺席，不把最新 SDK 编译成功算作最低系统通过。

达到这些证据后，才能决定预览桥接方式、最终容器编码、性能上限与支持矩阵。当前研究票可结束；原生实验及用户验收仍未完成。
