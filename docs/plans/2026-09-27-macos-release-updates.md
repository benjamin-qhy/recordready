# macOS 发布升级实施计划

用户已确认 ADR-0001、beta.1/10001 基线、beta.2/10002 验收版及中英文简洁下载页，并授权实施和部署。

## 架构与边界

Swift 原生更新控制器直接使用固定来源的 Sparkle 2.10.0；Tauri 只桥接状态与用户动作。原生主线程在安装确认前和最终退出前核对录制状态，并锁住新的录制请求。后台启动 2 秒后及每 4 小时只查信息；下载、安装均由用户触发。签名私钥仅保存在本机受限目录。

## 执行顺序与验证

- [x] 发布模型：先测试不合法版本、重复/倒退构建、错误域名、签名、增量来源和不可变产物，然后实现固定产品模型与 appcast。
- [x] 发布工具：适配海奇AI已验证脚本，固定 Sparkle 下载及校验，生成独立密钥，Tauri 产物完成修改后签名，生成 ZIP/DMG、验签与最近三版增量还原验证。文件置于 scripts/release/、site/。
- [x] 原生安装策略：先为忙碌/未知状态及安装锁测试失败，再实现独立策略与 Sparkle user driver。修改 desktop/native/Bridge.swift、desktop/src-tauri/build.rs 和 src/lib.rs，增加 desktop/native/Updater.swift。
- [x] 界面：设置页展示当前版本、检查/下载/稍后/重启、大小进度和可恢复错误；菜单检查更新；补中英文。
- [x] 本地验收：npm test、npm run build、npm run lint、原生策略测试及 cargo 检查；审查范围和退出竞争。
- [x] 站点部署：独立 Nginx 虚拟主机和 Certbot 证书；暂存、远端哈希核对、不可变版本、锁和清单最后切换。保留海奇AI配置。浏览器检查双语下载页。
- [x] 固定构建 beta.1 和 beta.2，公网真实完整包/增量升级，检查版本、签名、配置保留、权限与忙碌保护。明确记录无法验证项，不将脚本通过等同于真实升级成功。

命令入口：bun scripts/release/prepare-sparkle.ts；bun scripts/release/build-release.ts <version> <build> <notes.json>；bun scripts/release/build-site.ts；bun scripts/release/deploy-site.ts。

当前进度：两个固定构建、离线还原、HTTPS 部署、真实增量升级与完整包回退均已验证；实际录制和系统权限迁移保留验证边界。证据见 docs/implementation/2026-09-27-release-validation.md。
