# recordready

口播录制工具。

当前已有真实 macOS 录制工程及线上内测版；Windows x64 录制、安装与签名增量更新候选版已实现，服务器发布与剩余实机验收仍待完成。

- [macOS 工程与验证](desktop/README.md)
- [Windows 工程、构建与发布](desktop/windows/README.md)
- [Windows 当前验收记录](docs/implementation/2026-09-30-windows-validation.md)

以下为早期浏览器交互原型，其模拟状态不代表当前桌面工程。

## 第一期：单一极简录制界面

[打开原型](prototype/index.html)，无需先进入工作台。尺寸在上方；编辑稿件、字号、速度在提词区；摄像头设置在小窗旁；麦克风及保存目录在底部。停止后在当前界面显示独立视频文件结果。

[需求与技术架构](docs/口播录制工具-MVP方案.md)

## 第二期：原界面保留

[第二期原型](prototype/phase2/index.html)：保留原工作台、A/B/C 布局、最近录制等界面。第一期没有这些页面入口。

[分期前历史方案](docs/archive/口播录制工具-分期前方案.md)

## 运行

```sh
python3 -m http.server 4173 --bind 127.0.0.1
```

第一期：<http://127.0.0.1:4173/prototype/index.html>

第二期：<http://127.0.0.1:4173/prototype/phase2/index.html>

全部设备、音量、桌面画面、目录选择、录像与文件结果均为模拟。真实双平台采集、浮窗排除与音画同步仍待开发验证。

## 本次检查

内置浏览器已检查：首次直接进入单界面、提词字号、稿件编辑浮层、内置/外接摄像头选择、保存目录示例切换、开始/停止、双文件结果与原地再录。保存结果出现时仍停留在录制界面，工作台入口不可见。

[第一期配置原型图](prototype/screenshots/11-phase1-settings.png)
