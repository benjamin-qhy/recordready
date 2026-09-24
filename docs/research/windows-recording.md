# Windows 原生录制路径：官方依据与实验边界

调查日期：2026-09-24。对应 [Windows 原生录制路径：哪些 API 与版本约束有官方依据？](https://github.com/benjamin-qhy/recordready/issues/3)。基线为《口播录制工具-MVP方案》。本次只核查官方资料，未运行 Windows 程序、未取得真实样片，不代表 Windows 验收通过。

## 结论

Windows 11 x64 的候选链路有官方 API 依据：WGC 显示器采集 → 原生裁切/缩放 → Media Foundation 编码封装；MF 摄像头源同时供应原生预览和独立编码；单次 WASAPI 麦克风采集分发至两份文件。应进入最小原生实验，而非据此锁定性能、设备兼容性或预览桥接方案。下文“建议”均为待实验的工程推论，不是已确认的实现决定。

## 能力与限制

| 问题 | 官方依据 | 对本项目的含义 / 尚待证明 |
|---|---|---|
| 自身浮窗排除 | `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` 自 Windows 10 2004 支持；仅当前进程拥有的顶层 HWND，且要求 DWM 合成；旧版会退化成 `WDA_MONITOR`。它不是通用安全/DRM 保证。[API](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity) | Windows 11 满足版本门槛；对每个独立顶层提词、摄像头、工具、设置浮窗应用并检查返回值。不能只保护主窗口，不能假定 WebView 子窗口本身适用。必须在 WGC 编码后的屏幕视频确认浮窗消失且底下内容完整，无黑块。 |
| Tauri 与穿透 | Tauri 提供窗口内容保护和整窗忽略光标事件；`WM_NCHITTEST` 的 `HTTRANSPARENT` 只描述同线程下层窗口的传递，不是任意其他应用穿透保证。[Tauri Window](https://docs.rs/tauri/latest/tauri/window/struct.Window.html#method.set_content_protected)、[忽略事件](https://docs.rs/tauri/latest/tauri/window/struct.Window.html#method.set_ignore_cursor_events)、[命中测试](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nchittest) | CSS 透明不等于系统输入穿透。建议首先实验“整窗穿透线框 + 独立可交互控件窗口”，同时检查 focus、拖动、置顶、恢复按钮；需要混合区域命中时再验证原生方案。锁定 Tauri/tao 版本后核实实际 affinity 实现。 |
| 区域捕获 | WGC 捕获显示器/窗口，Win32 `CreateForMonitor` 从 1903 起可用。帧给出 `ContentSize`，底层表面可能大于有效内容；改变尺寸或设备丢失需重建帧池。[互操作](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createformonitor)、[采集指南](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) | 建议先捕获一台显示器，再按物理像素裁切选区及缩放输出；不要把 WGC item 当任意桌面矩形。跨显示器拼接是额外问题，先由规格确定是否支持，不能默认已实现。 |
| DPI | Microsoft 推荐 Per-Monitor V2，收到 `WM_DPICHANGED` 后更新布局与 DPI 数据，并测试混合 DPI。[DPI 指南](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows) | 记录显示器物理原点、选区物理坐标、UI 逻辑坐标和输出像素四者映射。负坐标、多屏缩放、跨屏拖动及取整应单测并实录标尺。1080×1920 输出不意味着桌面有同尺寸物理区域。 |
| 摄像头与预览 | MF 可以枚举和打开摄像头媒体源，经 Source Reader 获取样本，使用 Direct3D/Direct2D 预览，Sink Writer 写文件。[MF 采集](https://learn.microsoft.com/en-us/windows/win32/medfound/audio-video-capture-in-media-foundation) | 建议一个摄像头源分流，避免 WebView `getUserMedia` 再打开第二路设备。独立原生预览窗口/视图是待验证候选；布局和镜像只作用预览，不改录制源帧。官方未替本项目提供可直接接 Tauri DOM 的视频纹理通道。 |
| 容器编码 | MF 官方列出 MP4 sink、H.264 和 AAC 编码器。[格式表](https://learn.microsoft.com/en-us/windows/win32/medfound/supported-media-formats-in-media-foundation)、[MP4 sink](https://learn.microsoft.com/en-us/windows/win32/medfound/mpeg-4-file-sink) | 优先实验 SDR、H.264/AAC、MP4，具体 profile、色彩转换、码率、摄像头 native type 和帧率必须协商；不承诺任意 3840 边长或所有摄像头格式。 |
| 硬件与版本 | Sink Writer / Source Reader 默认不启用硬件 MFT；可设置 `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`。WGC 要运行时检查 `IsSupported`。[硬件属性](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-readwrite-enable-hardware-transforms)、[WGC 指南](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) | “启用硬件”不等于实际选中硬件或两路并发都可用。Windows 11 x64 是产品候选门槛，不是性能证书。记录 OS build、GPU/驱动、编码器、WebView2/Tauri 版本；软件回退和 Windows N 媒体组件缺失均需单独检查，尚未覆盖。 |

WGC 文档另指出 HDR 使用普通 BGRA8 路径可能色彩失真，需要浮点链路或 HDR→SDR tone mapping；因此建议首轮固定 SDR，HDR 的支持/拒绝策略留待规格决定。[HDR 注意事项](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)

## 单麦克风、双文件和共同时间轴

1. **麦克风只打开一次。** 建议一个 WASAPI capture endpoint 读取 PCM，复制到拥有明确生命周期的有界缓冲，再给两个独立 Sink Writer 的音频流。`GetBuffer` 返回内存只在 `ReleaseBuffer` 前有效，不能把其裸指针留给异步编码队列。[WASAPI GetBuffer](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)
2. **共用音频内容和时间戳，而非假定共用编码器。** 首轮可分别 AAC 编码同一 PCM，并记录 AAC 编码延迟及封装结果；两份有损音轨不保证字节一致。复用一次编码后的 AAC 是后续优化，不是本次已验证能力。Sink Writer 支持设置输入/输出媒体类型、样本时间和时长、写入及结束封装，这些构成分发方案的 API 基础。[Sink Writer 教程](https://learn.microsoft.com/en-us/windows/win32/medfound/tutorial--using-the-sink-writer-to-encode-video)
3. **屏幕与音频可关联 QPC。** WGC `SystemRelativeTime` 是 QPC 时间；WASAPI `pu64QPCPosition` 是包首帧关联 QPC，已经转换为 100ns，不能再次按 QPC 频率转换。音频同时提供设备帧位置及时间戳错误/不连续标记。[WGC](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)、[WASAPI](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer)
4. **摄像头时钟是重点未知。** `MFT_HW_TIMESTAMP_WITH_QPC_Attribute` 为 TRUE 表示硬件源采用 QPC，默认 FALSE 表示设备时钟。不能因为 MF 样本也是 100ns 就认定与 WGC 同一原点；需要查询/协商实际源、记录样本时钟行为及必要的映射。文档存在此属性不保证每个驱动接受设置。[QPC 属性](https://learn.microsoft.com/en-us/windows/win32/medfound/mft-hw-timestamp-with-qpc-attribute)
5. **建议归一化到同一个 session epoch。** 在各源稳定后选共同 `t0`；样本 PTS 以共同时间减 `t0`，处理起始缺帧/音频裁切，保留首帧偏移；不能把两条各自首帧都强制归零掩盖采集延迟。设备独立时钟需测量漂移，是否重采样由证据决定。顺序 start 和并行调用 start 都不构成同步证明。
6. **封装完成是保存完成条件。** 每个 Sink Writer 单独 `Finalize`，成功之后再认定相应文件完整；此调用负责完成待写样本及文件头更新。[Finalize](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsinkwriter-finalize) 双文件部分失败处理遵循现有 MVP 方案，不能用一个成功掩盖另一个失败。

## 最小原生实验建议（后续 HITL，不在本研究执行）

| 实验 | 最小操作及必须保存的证据 | 放行条件 |
|---|---|---|
| 浮窗/预览 | Windows 11 x64 实机，Tauri 透明线框、可点工具条、提词、D3D 摄像头预览；屏幕内放移动计时器，移动/重建所有浮窗、弹设置层，录 30 秒。保存真实 screen/camera 样片及窗口 affinity 返回日志。 | 屏幕无自身 UI、无替代黑块，底下移动内容可见；camera 无桌面；透明处可操作其他程序且控制区可用。 |
| 坐标 | 100%/150%/200% 缩放及可用的混合 DPI 双屏，负坐标显示器、横竖输出、边界选区。录制像素标尺。 | 输出尺寸正确，选区映射与实际画面相符；跨屏/超界场景明确拒绝或按已定义策略处理。 |
| 编码/同步 | 单麦克风、WGC、摄像头并行，H.264/AAC MP4 两文件；30 秒短录、连续三次、30 分钟长录；开头和末尾用同一个可见/可听物理事件，另录屏幕可见时间参考。 | 两份播放/解码通过，首尾音画及两视频相对偏差按基线 ≤200ms；保存测量方法、逐流 PTS、首帧偏移/时钟来源、丢帧、内存曲线。仅凭肉眼或同源音轨相关性不能证明视频同步。 |
| 资源边界 | 双编码器、预览拖动/镜像、摄像头关闭、设备拔出、目标目录写入失败。 | 记录实际硬件/软件编码路径、支持格式和失败结果；摄像头关闭不创建空文件；一文件失败保留另一文件；明确无界增长或达不到实时的能力边界。 |

尚未解决的产品决定：跨屏选区、HDR、最低性能机型及硬件回退策略；尚未证明的实现：Tauri 原生预览组合、每个窗口稳定排除、摄像头 QPC 映射、双编码器负载与 30 分钟同步。研究议题可以关闭，以上必须留在后续实验与决策议题中。
