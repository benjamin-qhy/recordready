// THROWAWAY NATIVE CAPABILITY PROBE — not the production app or Tauri integration.
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Darwin

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifacts = root.appendingPathComponent("artifacts")

func jsonWrite(_ value: Any, _ url: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

final class VideoFile {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let name: String
    var started = false
    var videoFrames = 0, audioBuffers = 0, backpressureDrops = 0
    var firstVideo: Double?, lastVideo: Double?, firstAudio: Double?, lastAudio: Double?
    var dimensions: [Int] = []
    init(directory: URL, name: String, width: Int, height: Int) throws {
        self.name = name
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(name + ".partial.mp4"), fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                              AVVideoExpectedSourceFrameRateKey: 30]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw ProbeError.message("writer 无法添加音视频输入") }
        writer.add(video); writer.add(audio)
    }
    func append(_ sample: CMSampleBuffer, video isVideo: Bool) throws {
        if !started {
            guard writer.startWriting() else { throw writer.error ?? ProbeError.message("startWriting 失败") }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        let input = isVideo ? video : audio
        guard writer.status == .writing else { throw writer.error ?? ProbeError.message("writer 未在写入") }
        guard input.isReadyForMoreMediaData else { backpressureDrops += 1; return }
        guard input.append(sample) else { throw writer.error ?? ProbeError.message("append 失败") }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if isVideo {
            videoFrames += 1; if firstVideo == nil { firstVideo = time }; lastVideo = time
            if let format = CMSampleBufferGetFormatDescription(sample) {
                let size = CMVideoFormatDescriptionGetDimensions(format); dimensions = [Int(size.width), Int(size.height)]
            }
        } else {
            audioBuffers += 1; if firstAudio == nil { firstAudio = time }; lastAudio = time
        }
    }
    func summary() -> [String: Any] {
        return ["name": name, "videoFrames": videoFrames, "audioBuffers": audioBuffers,
                "backpressureDrops": backpressureDrops, "inputVideoDimensions": dimensions,
                "firstVideoPTS": firstVideo as Any? ?? NSNull(), "lastVideoPTS": lastVideo as Any? ?? NSNull(),
                "firstAudioPTS": firstAudio as Any? ?? NSNull(), "lastAudioPTS": lastAudio as Any? ?? NSNull(),
                "writerStatus": writer.status.rawValue, "error": writer.error?.localizedDescription as Any? ?? NSNull()]
    }
    func finish(in directory: URL) async -> String {
        guard started else { writer.cancelWriting(); return "没有收到采样" }
        guard writer.status == .writing else { return writer.error?.localizedDescription ?? "writer 失败" }
        video.markAsFinished(); audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return writer.error?.localizedDescription ?? "封装失败" }
        do {
            try FileManager.default.moveItem(at: directory.appendingPathComponent(name + ".partial.mp4"),
                                            to: directory.appendingPathComponent(name + ".mp4"))
            return "saved"
        } catch { return error.localizedDescription }
    }
}

enum ProbeError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

final class Engine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "recordready.probe.samples")
    let setupQueue = DispatchQueue(label: "recordready.probe.capture")
    let session = AVCaptureSession()
    var stream: SCStream?
    var screenFile: VideoFile?, cameraFile: VideoFile?
    var epoch = CMTime.zero
    var recording = false
    var configured = false
    var directory: URL?
    var fatalError: String?
    var metadata: [String: Any] = [:]
    var onFailure: ((String) -> Void)?
    var latestAudioLevel = 0.0
    var logHandle: FileHandle?
    var loggedCounts: [String: Int] = [:]

    func configureDevices() throws {
        if configured { return }
        guard let camera = AVCaptureDevice.default(for: .video), let microphone = AVCaptureDevice.default(for: .audio) else {
            throw ProbeError.message("未找到默认相机或麦克风")
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration() }
        for device in [camera, microphone] {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ProbeError.message("无法连接设备 \(device.localizedName)") }
            session.addInput(input)
        }
        let cameraOutput = AVCaptureVideoDataOutput()
        cameraOutput.alwaysDiscardsLateVideoFrames = true
        cameraOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        cameraOutput.setSampleBufferDelegate(self, queue: queue)
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        for output in [cameraOutput as AVCaptureOutput, audioOutput as AVCaptureOutput] {
            guard session.canAddOutput(output) else { throw ProbeError.message("无法连接设备输出") }
            session.addOutput(output)
        }
        metadata["cameraDevice"] = camera.localizedName
        metadata["microphone"] = microphone.localizedName
        configured = true
    }

    func start(displayID: CGDirectDisplayID, rectangle: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ProbeError.message("找不到主显示器")
        }
        guard let currentApp = content.applications.first(where: { $0.processID == getpid() }) else {
            throw ProbeError.message("找不到当前应用，无法保证浮窗排除")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [currentApp], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 1280; config.height = 720
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.sourceRect = rectangle
        config.showsCursor = true
        config.capturesAudio = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        let folder = artifacts.appendingPathComponent("PROTOTYPE-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + String(UUID().uuidString.prefix(6)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        guard let cameraInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) else {
            throw ProbeError.message("无法读取相机实际画幅")
        }
        let cameraDimensions = CMVideoFormatDescriptionGetDimensions(cameraInput.device.activeFormat.formatDescription)
        screenFile = try VideoFile(directory: folder, name: "screen", width: 1280, height: 720)
        cameraFile = try VideoFile(directory: folder, name: "camera", width: Int(cameraDimensions.width), height: Int(cameraDimensions.height))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("samples.jsonl").path, contents: nil)
        logHandle = try FileHandle(forWritingTo: folder.appendingPathComponent("samples.jsonl"))
        loggedCounts = [:]; fatalError = nil
        metadata["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        metadata["architecture"] = "arm64"
        metadata["displayLogicalSize"] = [display.width, display.height]
        // Keep API-reported size distinct from active mode pixels and physical panel resolution.
        metadata["cgDisplayReportedSize"] = [CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID)]
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            metadata["displayModeSize"] = [mode.width, mode.height]
            metadata["displayModePixelSize"] = [mode.pixelWidth, mode.pixelHeight]
        }
        metadata["sourceRectPoints"] = [rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height]
        metadata["outputPixels"] = [1280, 720]
        metadata["cameraOutputPixels"] = [cameraDimensions.width, cameraDimensions.height]
        metadata["excludedApplicationPID"] = getpid()
        metadata["framework"] = "AppKit + ScreenCaptureKit + AVFoundation (not Tauri)"
        metadata["startedAt"] = ISO8601DateFormatter().string(from: Date())
        metadata["state"] = "preparing"
        jsonWrite(metadata, folder.appendingPathComponent("session.json"))
        // Run both producers before opening the recording gate. The same host-clock epoch
        // applies to all streams; each sample is converted from its actual source clock.
        try await newStream.startCapture()
        queue.sync {
            epoch = CMClockGetTime(CMClockGetHostTimeClock())
            recording = true
        }
    }

    func normalized(_ sample: CMSampleBuffer, from clock: CMClock) throws -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        let hostPTS = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock())
        let pts = CMTimeSubtract(hostPTS, epoch)
        guard pts.isNumeric else { throw ProbeError.message("时钟映射无效") }
        // Whole pre-epoch buffers are dropped in this minimal experiment; record the first
        // actual sample offset instead of independently zeroing each source.
        guard pts >= .zero else { return nil }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else {
            throw ProbeError.message("采样缺少时间信息")
        }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let result = timing.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: $0.baseAddress, entriesNeededOut: &count)
        }
        guard result == noErr else { throw ProbeError.message("读取时间信息失败") }
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(CMSyncConvertTime(timing[i].presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()), epoch)
            if timing[i].decodeTimeStamp.isNumeric {
                timing[i].decodeTimeStamp = CMTimeSubtract(CMSyncConvertTime(timing[i].decodeTimeStamp, from: clock, to: CMClockGetHostTimeClock()), epoch)
            }
        }
        var output: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress!, sampleBufferOut: &output)
        }
        guard status == noErr, let copy = output else { throw ProbeError.message("重定时失败：\(status)") }
        return copy
    }

    func log(_ track: String, sample: CMSampleBuffer) {
        let n = (loggedCounts[track] ?? 0) + 1; loggedCounts[track] = n
        // First ten plus each 30th sample: bounded data rate, enough to inspect continuity.
        if n <= 10 || n % 30 == 0 {
            let row: [String: Any] = ["track": track, "n": n, "pts": CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                      "duration": CMSampleBufferGetDuration(sample).seconds.isFinite ? CMSampleBufferGetDuration(sample).seconds : 0]
            if var data = try? JSONSerialization.data(withJSONObject: row) { data.append(10); try? logHandle?.write(contentsOf: data) }
        }
    }
    func fail(_ error: Error) {
        guard fatalError == nil else { return }
        fatalError = error.localizedDescription
        recording = false
        DispatchQueue.main.async { self.onFailure?(error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard recording, type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        do {
            guard let clock = stream.synchronizationClock else { throw ProbeError.message("屏幕采集没有同步时钟") }
            if let sample = try normalized(sampleBuffer, from: clock) { try screenFile?.append(sample, video: true); log("screen", sample: sample) }
        } catch { fail(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail(error) } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else { return }
        do {
            guard let clock = session.synchronizationClock else { throw ProbeError.message("相机/音频没有同步时钟") }
            guard let sample = try normalized(sampleBuffer, from: clock) else { return }
            if output is AVCaptureVideoDataOutput {
                try cameraFile?.append(sample, video: true); log("camera", sample: sample)
            } else {
                try screenFile?.append(sample, video: false)
                try cameraFile?.append(sample, video: false)
                log("microphone-once", sample: sample)
            }
        } catch { fail(error) }
    }
    func stop() async -> String {
        queue.sync { recording = false }
        if let stream = stream { try? await stream.stopCapture() }
        stream = nil
        guard let folder = directory else { return "尚无会话" }
        let a = await screenFile?.finish(in: folder) ?? "无屏幕文件"
        let b = await cameraFile?.finish(in: folder) ?? "无摄像头文件"
        metadata["screen"] = screenFile?.summary()
        metadata["camera"] = cameraFile?.summary()
        metadata["saveResults"] = ["screen": a, "camera": b]
        metadata["fatalError"] = fatalError as Any? ?? NSNull()
        metadata["state"] = a == "saved" && b == "saved" ? "saved" : "partial-or-failed"
        metadata["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        jsonWrite(metadata, folder.appendingPathComponent("session.json"))
        try? logHandle?.close(); logHandle = nil
        return "screen: \(a) · camera: \(b)\n\(folder.lastPathComponent)"
    }
}

final class Preview: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        wantsLayer = true; layer = CALayer(); preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = Engine()
    var controls: NSWindow!, frameWindow: NSWindow!, promptWindow: NSWindow!, cameraWindow: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "未采集。先点击“授权并预览”，再开始实验。")
    let permissionButton = NSButton(title: "授权并预览", target: nil, action: nil)
    let startButton = NSButton(title: "开始实验", target: nil, action: nil)
    let stopButton = NSButton(title: "停止并保存", target: nil, action: nil)
    let durationMenu = NSPopUpButton()
    var duration = 30.0, startedAt: Date?, timer: Timer?
    var busy = false
    var isRecording = false
    var rect = CGRect.zero
    var displayID: CGDirectDisplayID = 0
    var resourceSamples: [[String: Any]] = []
    var motionSamples: [[String: Any]] = []
    var originalPromptFrame = NSRect.zero, originalCameraFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let screen = NSScreen.screens.first!
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        // Fixed, visible 16:9 sample region in display points, scaled to 1280x720 output.
        let w = min(960.0, screen.frame.width - 100), h = w * 9 / 16
        let x = (screen.frame.width - w) / 2, y = (screen.frame.height - h) / 2
        rect = CGRect(x: x, y: y, width: w, height: h)
        frameWindow = NSWindow(contentRect: NSRect(x: screen.frame.minX+x, y: screen.frame.maxY-y-h, width: w, height: h), styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false; frameWindow.backgroundColor = .clear; frameWindow.level = .floating
        frameWindow.ignoresMouseEvents = true; frameWindow.hasShadow = false
        frameWindow.contentView?.wantsLayer = true
        frameWindow.contentView?.layer?.borderWidth = 5
        frameWindow.contentView?.layer?.borderColor = NSColor.systemPink.cgColor
        frameWindow.orderFrontRegardless()
        promptWindow = NSWindow(contentRect: NSRect(x: frameWindow.frame.minX+60, y: frameWindow.frame.maxY-120, width: w-120, height: 85), styleMask: [.titled], backing: .buffered, defer: false)
        promptWindow.title = "提词浮窗 · 屏幕视频中必须消失"
        promptWindow.level = .floating; promptWindow.isMovableByWindowBackground = true
        let prompt = NSTextField(wrappingLabelWithString: "EXCLUDE ME / 提词排除标记\n拖动相机和提词窗，操作下方应用。开始和结束时拍手，用于后续测量。")
        prompt.font = .systemFont(ofSize: 20, weight: .semibold); prompt.textColor = .systemPink
        prompt.frame = NSRect(x: 15, y: 8, width: w-150, height: 65)
        promptWindow.contentView?.addSubview(prompt); promptWindow.orderFrontRegardless()
        cameraWindow = NSWindow(contentRect: NSRect(x: frameWindow.frame.maxX-330, y: frameWindow.frame.minY+10, width: 320, height: 180), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        cameraWindow.title = "摄像头预览 · 可拖动"; cameraWindow.level = .floating
        cameraWindow.contentView = Preview(session: engine.session)
        cameraWindow.orderFrontRegardless()
        controls = NSWindow(contentRect: NSRect(x: 80, y: 70, width: 700, height: 230), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        controls.title = "RecordReady · 临时 macOS 原生实验（非正式应用）"
        controls.delegate = self; controls.level = .floating
        let heading = NSTextField(labelWithString: "屏幕 1280×720 · 相机原画幅 · H.264/AAC · 双文件")
        heading.font = .systemFont(ofSize: 17, weight: .semibold); heading.frame = NSRect(x: 20, y: 187, width: 660, height: 25)
        controls.contentView?.addSubview(heading)
        status.frame = NSRect(x: 20, y: 75, width: 660, height: 95)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        controls.contentView?.addSubview(status)
        durationMenu.addItems(withTitles: ["30 秒", "30 分钟"]); durationMenu.frame = NSRect(x: 20, y: 25, width: 105, height: 30)
        controls.contentView?.addSubview(durationMenu)
        for (button, title, selector, left) in [(permissionButton, "授权并预览", #selector(authorize), 140.0),
                                                  (startButton, "开始实验", #selector(start), 275.0),
                                                  (stopButton, "停止并保存", #selector(stop), 400.0)] {
            button.title = title; button.target = self; button.action = selector
            button.frame = NSRect(x: left, y: 25, width: 125, height: 32); button.bezelStyle = .rounded
            controls.contentView?.addSubview(button)
        }
        let reveal = NSButton(title: "打开样片目录", target: self, action: #selector(openResults))
        reveal.frame = NSRect(x: 540, y: 25, width: 135, height: 32); reveal.bezelStyle = .rounded
        controls.contentView?.addSubview(reveal)
        startButton.isEnabled = false; stopButton.isEnabled = false
        engine.onFailure = { [weak self] message in self?.status.stringValue = "采集失败：\(message)"; self?.stop() }
        controls.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "退出实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        writeState("idle")
    }
    func writeState(_ state: String) {
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        jsonWrite(["state":state,"status":status.stringValue,"screenPermission":CGPreflightScreenCaptureAccess(),
                   "cameraPermission":AVCaptureDevice.authorizationStatus(for:.video).rawValue,
                   "microphonePermission":AVCaptureDevice.authorizationStatus(for:.audio).rawValue,
                   "sessionDirectory":engine.directory?.path ?? ""], artifacts.appendingPathComponent("probe-state.json"))
    }
    @objc func authorize() {
        permissionButton.isEnabled = false
        status.stringValue = "等待系统权限。系统设置修改屏幕权限后可能需要退出并重新打开此实验。"
        writeState("permissions")
        Task { @MainActor in
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            guard camera && microphone && screen else {
                status.stringValue = "权限未齐：屏幕 \(screen)，摄像头 \(camera)，麦克风 \(microphone)。\n请在系统设置 → 隐私与安全性授权，然后重新打开实验。"
                permissionButton.isEnabled = true; writeState("permission-required"); return
            }
            do {
                try engine.configureDevices()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    engine.setupQueue.async { self.engine.session.startRunning(); c.resume() }
                }
                status.stringValue = "预览就绪。粉色线框是屏幕选区；自身三个浮窗必须从录屏消失。\n按开始将记录屏幕选区、相机与麦克风，文件只保存在本机。"
                startButton.isEnabled = true; writeState("ready")
            } catch { status.stringValue = error.localizedDescription; permissionButton.isEnabled = true; writeState("failed") }
        }
    }
    @objc func start() {
        guard !busy, !isRecording else { return }
        busy = true; startButton.isEnabled = false; durationMenu.isEnabled = false
        duration = durationMenu.indexOfSelectedItem == 1 ? 1800 : 30
        status.stringValue = "准备录制…"; writeState("preparing")
        Task { @MainActor in
            do {
                try await engine.start(displayID: displayID, rectangle: rect)
                busy = false; isRecording = true; stopButton.isEnabled = true; startedAt = Date(); resourceSamples = []; motionSamples = []
                originalPromptFrame = promptWindow.frame; originalCameraFrame = cameraWindow.frame
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                tick()
            } catch {
                status.stringValue = "启动失败：\(error.localizedDescription)"
                _ = await engine.stop()
                busy = false; startButton.isEnabled = true; durationMenu.isEnabled = true; writeState("failed")
            }
        }
    }
    func tick() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        // Temporary experiment only: move both excluded windows across the source.
        if elapsed >= 5 && elapsed < 25 {
            let phase = min(1.0, (elapsed - 5) / 19)
            let bounds = frameWindow.frame
            promptWindow.setFrameOrigin(NSPoint(x: bounds.minX + phase * (bounds.width - promptWindow.frame.width), y: bounds.midY + 40))
            cameraWindow.setFrameOrigin(NSPoint(x: bounds.minX + (1-phase) * (bounds.width - cameraWindow.frame.width), y: bounds.midY - cameraWindow.frame.height))
        }
        func coordinates(_ window: NSWindow) -> [CGFloat] { let f = window.frame; return [f.minX, f.minY, f.width, f.height] }
        motionSamples.append(["elapsed": elapsed, "hostClock": CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                              "promptFrame": coordinates(promptWindow), "cameraFrame": coordinates(cameraWindow), "captureFrame": coordinates(frameWindow)])
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        let rss = result == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1
        resourceSamples.append(["elapsed": elapsed, "residentMB": rss])
        let stats = engine.queue.sync { "screen \(engine.screenFile?.videoFrames ?? 0) 帧 · camera \(engine.cameraFile?.videoFrames ?? 0) 帧 · mic \(engine.screenFile?.audioBuffers ?? 0) 包" }
        status.stringValue = "录制中 \(Int(elapsed)) / \(Int(duration)) 秒 · RSS \(Int(rss)) MB\n\(stats)\n第 5–25 秒自动移动提词及相机窗；无需手动操作。"
        writeState("recording")
        if elapsed >= duration { stop() }
    }
    @objc func stop() {
        guard !busy, isRecording else { return }
        isRecording = false; busy = true; timer?.invalidate(); timer = nil
        stopButton.isEnabled = false; status.stringValue = "正在停止采集并封装两份文件…"; writeState("saving")
        Task { @MainActor in
            let result = await engine.stop()
            if let folder = engine.directory {
                jsonWrite(resourceSamples, folder.appendingPathComponent("memory.json"))
                jsonWrite(motionSamples, folder.appendingPathComponent("window-motion.json"))
            }
            promptWindow.setFrame(originalPromptFrame, display: true)
            cameraWindow.setFrame(originalCameraFrame, display: true)
            status.stringValue = result; busy = false; startButton.isEnabled = true; durationMenu.isEnabled = true; writeState("finished")
        }
    }
    @objc func openResults() { NSWorkspace.shared.open(engine.directory ?? artifacts) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isRecording { stop(); return false }
        if busy { return false }
        NSApp.terminate(nil); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRecording { stop(); return .terminateCancel }
        return busy ? .terminateCancel : .terminateNow
    }
}

let delegate = App()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
