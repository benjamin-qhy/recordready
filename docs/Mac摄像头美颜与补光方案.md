# Mac 摄像头美颜与补光方案

> 本文保留早期方案与原型决策；正式实现及当前验收状态以 [摄像头效果接入验收](摄像头效果接入验收.md) 为准，部分交互、命名和处理队列方案已调整。

## 当前范围

用户已确认 macOS 先行、为 Windows 预留扩展；磨皮和瘦脸可按 0–100% 调整、设置中实时预览。真人原型评审后，用户要求移除虚拟背景并增加不同光位的补光。本文以最新要求为准。

- 磨皮、瘦脸、补光分别为 0–100% 整数强度；0 为关闭，100 为经过真人评审的最大效果。
- 补光提供正面柔光、画面左前柔光、画面右前柔光，三者各自 0–100%，可同时开启。叠加时使用平滑亮度上限与高光保护。左右以未镜像的输出画面为准，界面必须明确方向。
- 原型验证面部局部补光：随人脸位置移动，柔和提亮所选方向，限制高光过曝。
- 效果在预览中立即显示，camera.mp4 使用同一处理画面；不额外编码一份摄像头原片。
- macOS 13+、Apple Silicon、纯本地处理，无第三方模型下载、Python 环境或推理框架安装。
- 虚拟背景已经移出范围；不制作或分发背景库。

## 补光能力边界

首版是二维面部局部补光，根据脸的位置和选定方向调整亮度分布。其目标是改善暗脸和左右受光不均。没有真实深度、表面法线或专门的重打光模型，不承诺重新生成鼻影、轮廓光、眼部灯光反射，也不能恢复原图中过曝或全黑区域丢失的细节。

在近似线性光空间内提升亮度，使用柔和高光压缩避免硬剪裁。磨皮保留眼睛、嘴唇和基本纹理；补光作用于完整面部区域，边缘渐变。没有检测到人脸时停止面部效果，不将旧位置当作当前脸部使用。

## 设置交互

摄像头小窗齿轮菜单新增“美颜与补光…”，打开预览旁的设置面板。面板显示三个滑杆和当前百分比，以及补光方向选项和“恢复默认”。默认三项均关闭。

拖动中数值立即更新，向原生端合并提交最新配置，不等待松手，不依赖状态轮询。参数用递增 revision 避免旧响应覆盖新值。松手和关闭设置时保存最后值，重开与重启后恢复。

准备阶段自由调节，倒计时开始至保存完成锁定配置。录制使用开始时的快照。未启用摄像头时提供启用入口，遵循系统授权流程。前端沿用中英文、主题和键盘操作。

镜像、小窗形状和布局属于预览变换，不改变摄像头视频画幅；“效果一致”不要求将圆形预览裁切写入视频。

## 原生处理流程

```text
AVFoundation 摄像头帧 → 时间戳与会话身份
  → 有界处理队列 → Vision 人脸关键点
  → Metal 局部磨皮 → 局部瘦脸 → 人脸补光
  → 同一处理后的像素缓冲区
      ├→ 原生 Metal 预览
      └→ 保留采集时间的写入样本 → camera.mp4
```

正式应用目前在 `desktop/native/CaptureEngine.swift` 直接写原始摄像头帧，`desktop/native/Bridge.swift` 使用 AVCaptureVideoPreviewLayer。需用能显示处理结果的 Metal 视图替换该预览层。图像帧始终留在 Swift/Metal 中，WebView 只交换配置和状态。

共用 CIContext、纹理缓存和像素缓冲池。Vision 不阻塞屏幕、音频回调。处理队列至多保留一个处理中帧和一个可替换的待处理帧；预览只保留最新帧。所有效果为 0 时跳过 Vision 和着色器。

采集时固定会话 generation、暂停换算时间和配置 revision；结果返回时验证身份。停止、暂停和设备切换后拒绝旧帧。时间戳使用采集时间，不能改成处理完成时间。

停止摄像头使用独立会话队列，禁止主线程同步等待视频回调队列执行 stopRunning。原型曾实际遇到此退出阻塞，正式实现须覆盖这条生命周期分支。

## Windows 扩展契约

共享配置包含 `schemaVersion`、`smoothingPercent`、`faceSlimPercent`、`frontLightPercent`、`leftLightPercent`、`rightLightPercent` 和 `revision`。

平台后端返回可用能力、实际生效参数与失败原因。Swift 的 Vision 类型、CIImage、Metal 纹理不进入共享协议。Windows 未来用自己的关键点与 GPU 后端实现同一配置语义；各平台的百分比是归一化强度，不保证逐像素相同。

## 原型与实施顺序

原型位于 `prototype/camera-effects/`，是独立 AppKit 应用，仅用于验证真实摄像头、滑杆、光位和效果样片；它不采集屏幕或音频，不等同于正式应用验收。

1. 真人评审三种光位和强度上限；记录 0、50、100% 以及组合开启时的观感与帧率。
2. 正式配置模型：新增 `desktop/native/CameraEffectsConfiguration.swift`，更新 `desktop/src/lib/session.ts` 和 `Bridge.swift` 的验证、持久化与状态快照。
3. 统一图像路径：新增 `CameraFrameProcessor.swift`、`CameraPreviewView.swift`、`CameraEffects.metal`；修改 `CaptureEngine.swift`，先验证原图贯通与同步，再启用三项效果。
4. 设置面板：新增 `desktop/src/components/CameraEffectsPanel.tsx`，更新 `App.tsx`、`index.css`、`lib/i18n.ts`、`src-tauri/src/lib.rs` 的入口、尺寸和锁定状态。
5. 构建：`desktop/src-tauri/build.rs` 与原生测试脚本纳入新增 Swift 文件及 Metal 资源，链接 Vision/CoreImage/Metal/MetalKit，验证独立安装包资源加载。
6. 文案：`CONTEXT.md` 和输出界面使用“摄像头视频”作为通用名称；“原片”仅用于全部效果关闭的画面。
7. 集中验证：真实短录、暂停恢复、同步、退出与设备故障；固定最后一次构建的 app 后执行授权及验收。

## 验收标准

- 三个百分比滑杆独立连续生效；调节不被旧状态回写。
- 左右光位产生对应亮度差异，正面柔光整体提亮脸部；远处背景不被一起提亮。
- 全部为 0 时保持原始画面；无脸、侧转、遮挡、重新入画不产生固定位置的错误亮斑或变形。
- 正脸、侧脸、眼镜、低光、左右不均匀光照下评审自然程度；效果上限由真人样片决定。
- 原型以实际摄像头尺寸记录性能。正式目标为源支持 30 fps 时组合短录平均不低于 28 fps，参数变化通常在 100 ms 内可见。不能以编译成功代替性能验收。
- 预览与导出使用同一参数和处理结果；摄像头音画、屏幕音画同步及暂停恢复不退化。
- 录制结束时无旧帧跨会话写入，关闭程序不会卡死，已开始保存的样片完整结束。
- 自动验证重点是零强度旁路、光位方向、局部亮度边界、无脸降级、时间戳与过期会话；真实画质仍需用户评审。
- 正式项目检查沿用 `cd desktop && npm test && npm run build && bash scripts/test-native.sh`，并运行 `git diff --check`。

## 资料依据

- [Apple 实时滤镜采集与 Metal 预览](https://developer.apple.com/documentation/avfoundation/avcamfilter-applying-filters-to-a-capture-stream)
- [Apple 人脸关键点](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
- [Apple 曝光调整](https://developer.apple.com/documentation/coreimage/ciexposureadjust)
- [Apple 高光与阴影调整](https://developer.apple.com/documentation/coreimage/cihighlightshadowadjust)

这些资料支持本地实时图像处理路线；原型采用自定义 Metal 着色器计算方向性补光，官方通用滤镜本身不是自动三维重打光算法。

## 2026-09-27 更新：优先使用 macOS 系统效果

用户最新决定：恢复测试苹果系统背景替换；Mac 优先使用系统取景、人物居中、摄影室灯光、屏幕补光、人像虚化等能力。此前取消的是自制背景分割方案，不再作为系统背景测试的限制。

配置分为 macOS 系统能力与通用效果。原型已加入系统面板入口、人物居中开关及活动状态显示，通用磨皮/瘦脸/补光由独立总开关启用，默认关闭，允许按需叠加。不能以只读系统属性制作虚假的应用内强度控制。

Windows 复用通用参数和算法设计，需要独立实现检测/渲染后端；当前 Swift/Vision/Metal 原型未完成 Windows 移植。正式应用集成仍待原型效果验收。桌上视角和演讲者叠加不等同于 camera.mp4 的普通帧效果，仅能由系统提供相应流程，不宣称已录入。
