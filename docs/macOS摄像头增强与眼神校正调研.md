# macOS 摄像头增强与眼神校正调研

日期：2026-09-27。范围：RecordReady 的单人口播；macOS 优先，保留 Windows 后端；轻量、本地优先，不要求用户额外安装大模型。本次只调研与读取设备能力，没有安装模型、上传录制素材或修改录制功能。

## 结论

优先验证系统人物居中、系统补光和靠近镜头的提词布局。眼神校正有现成产品和本地研究实现，但没有查到可供普通 macOS 摄像头采集直接使用的 Apple 公开眼神校正 API。不能把 iPhone FaceTime 的功能视为 Mac 应用可调用接口。

眼神校正应先用独立样片验证，效果自然、速度和许可均满足要求后再集成。可以将小型模型随应用打包，从而免去用户手动安装；这仍属于模型推理，不能称为无模型处理。

## 系统功能与用途

| 功能 | 对口播的价值 | 实现与边界 |
|---|---|---|
| Center Stage 人物居中 | 移动时自动调整取景 | 设备支持时使用系统能力；自动裁切可能使人物变大，与宽取景需求存在取舍 |
| 手动取景、平移、重新居中 | 固定构图与更宽视野 | 支持机型通过系统视频菜单调整；0.5×能力取决于设备，不应自造更宽画面 |
| Studio Light 摄影室灯光 | 提亮脸部并压暗背景 | 系统算法；不等同于三个任意位置的虚拟灯 |
| Edge Light 屏幕补光 | 屏幕发光照亮真人 | Apple Silicon + macOS 26.2 起；可调亮度、色温。不是头发边缘的轮廓光 |
| Portrait 人像虚化 | 弱化环境干扰 | 有人物边缘问题的可能，需实测；用户已取消换背景，不默认纳入当前方案 |
| 背景替换 | 隐藏真实环境 | 系统具备，当前需求明确排除 |
| Reactions 手势特效 | 手势触发装饰效果 | 商务录制建议检查是否关闭，以免动作意外触发 |
| Desk View 桌上视角 | 展示实物和桌面操作 | 取决于设备；属于额外视角，不是眼神校正 |
| Presenter Overlay 演讲者叠加 | 共享屏幕时显示人像 | 面向共享流程，不应假定自动写入独立 camera.mp4 |

来源：[Apple 视频效果说明](https://support.apple.com/en-us/105117)、[Edge Light](https://support.apple.com/en-us/125934)、[连续互通相机开发讲解](https://developer.apple.com/videos/play/wwdc2022/10018/)。

## 本机实测与开发接口

通过只读 Swift/AVFoundation 查询当前默认 MacBook Pro 相机：活动格式支持 Center Stage、Portrait、Studio Light、Reactions 和 Background Replacement；查询时人物居中、人像、摄影室灯光和背景替换均未激活。这只证明能力标志，不证明录制成片已验收。

本机 SDK 的 AVCaptureDevice.h 确认：

- Center Stage 提供 controlMode 与 enabled，可采用 cooperative 模式并观察用户状态变化。
- Portrait、Studio Light 和 Background Replacement 的 enabled/active 是只读状态，不能假定每种系统效果都能由应用直接设置强度。
- `AVCaptureDevice.showSystemUserInterface(.videoEffects)` 可打开系统视频效果界面，适合作为轻量入口。
- 没有查到公开的 macOS gaze/eye-contact correction 开关。Vision 的人脸关键点检测本身不生成校正后的眼睛。

来源：[系统效果 API](https://developer.apple.com/documentation/avfoundation/system-video-effects-and-microphone-modes)、[打开系统效果界面](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface(_:))。本地接口证据：Xcode Command Line Tools SDK 的 AVFoundation/AVCaptureDevice.h。

接入后必须以实际 AVAssetWriter 样片确认系统效果进入录制管线，并避免系统摄影室灯光与自定义补光同时过强。此前系统菜单自动化超时，所以尚未完成系统 0.5× 实际画面对比。

## 眼神校正路线

| 路线 | 适配当前需求的判断 |
|---|---|
| Descript Eye Contact | 可对录好的视频校正，处理需联网且使用 AI Credits；适合效果对标，不是可直接嵌入的免费本地 SDK |
| NVIDIA Broadcast | 实时眼神校正的产品参考，但官方要求 Windows 与支持的 NVIDIA RTX GPU，不适用于当前 Mac |
| Core ML 本地开源实现 | 有候选，需检查代码、模型及上游权重许可；本机质量与端到端速度尚未实测 |
| 仅移动虹膜或眼部像素 | 不建议作为正式效果；视线变化涉及眼睑、眼白、遮挡和时间连续性，简单变形可能不自然（工程判断） |
| 靠近镜头的提词布局 | 无需模型；缩窄每行宽度，把当前行放在镜头附近，减少眼睛横向扫读，作为优先产品改进建议 |

来源：[Descript 帮助](https://help.descript.com/effects-animations-transitions/eye-contact)、[NVIDIA Broadcast](https://www.nvidia.com/en-us/design-visualization/software/broadcast-app/)。开源证据另见 [眼神校正开源方案调研](眼神校正开源方案调研.md)。

## 眼神校正的验收重点

Descript 官方也要求单人、眼睛清晰、光线良好、视线接近镜头；大幅偏头和眼镜反光会导致不自然或跳过处理。因此产品不能承诺看任意位置都能自然改为直视镜头。

建议先测试 30–60 秒样片：正常读稿、眨眼、戴眼镜、轻微转头、短暂看向别处。比较原片与处理片的眼神自然度、眼镜边缘、眨眼、跳变及耗时。目标是自然交流，低置信度时保留原眼神，而不是全程强制直视。

先考虑录后可选处理并保留原片，独立导出，避免把不可逆的眼睛伪影写进唯一源文件。实时预览与实时录制是否值得做，取决于前述样片结果和许可检查。

## 建议优先级

1. 系统视频效果入口 + 人物居中能力/状态展示，验证录制链路。
2. 镜头附近的窄幅提词布局；优先减少原始视线偏差。
3. 本地眼神校正仅做独立可行性验证；模型可以内置，但体积、依赖、商用许可和观感未过关前不承诺集成。
4. 继续保留当前磨皮、瘦脸、三方向补光；背景替换保持取消。

以上为调研建议，不代表新增功能已经开发或眼神校正已通过实机验证。
