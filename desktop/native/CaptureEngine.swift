// Native capture module extracted from the validated probe.
// All sample callbacks and writer mutations are serialized on queue.
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Darwin

var artifacts = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("RecordReady")

func jsonWrite(_ value: Any, _ url: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

final class VideoFile {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    let name: String
    var started = false
    var videoFrames = 0, audioBuffers = 0, backpressureDrops = 0
    var firstVideo: Double?, lastVideo: Double?, firstAudio: Double?, lastAudio: Double?
    var dimensions: [Int] = []
    init(directory: URL, name: String, width: Int, height: Int, includeAudio: Bool = true) throws {
        self.name = name
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(name + ".partial.mp4"), fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                              AVVideoExpectedSourceFrameRateKey: 30]
        ])
        audio = includeAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000
        ]) : nil
        video.expectsMediaDataInRealTime = true
        audio?.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), audio.map({ writer.canAdd($0) }) ?? true else { throw ProbeError.message("writer 无法添加音视频输入") }
        writer.add(video); if let audio = audio { writer.add(audio) }
    }
    func append(_ sample: CMSampleBuffer, video isVideo: Bool, requireReady: Bool = false) throws {
        if !started {
            guard writer.startWriting() else { throw writer.error ?? ProbeError.message("startWriting 失败") }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        guard let input = isVideo ? video : audio else { return }
        guard writer.status == .writing else { throw writer.error ?? ProbeError.message("writer 未在写入") }
        guard input.isReadyForMoreMediaData else {
            backpressureDrops += 1
            if requireReady { throw ProbeError.message("screen_encoder_overloaded") }
            return
        }
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
        guard started, videoFrames > 0 else { writer.cancelWriting(); return "没有收到视频采样" }
        guard writer.status == .writing else { return writer.error?.localizedDescription ?? "writer 失败" }
        video.markAsFinished(); audio?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return writer.error?.localizedDescription ?? "封装失败" }
        do {
            try FileManager.default.moveItem(at: directory.appendingPathComponent(name + ".partial.mp4"),
                                            to: directory.appendingPathComponent(name + ".mp4"))
            return "saved"
        } catch { return error.localizedDescription }
    }
}

// Serialized on Engine.queue. Keep the source clock; duplicate the latest image
// on a 30 Hz grid instead of treating ScreenCaptureKit's update rate as CFR.
final class ScreenFramePacer {
    var latest: CMSampleBuffer?
    var nextIndex: Int64 = 0
    var repeatedFrames = 0
    private var usedLatest = false

    func offer(_ sample: CMSampleBuffer, emit: (CMSampleBuffer) throws -> Void) throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric, pts >= .zero else { return }
        if latest == nil {
            nextIndex = CMTimeConvertScale(pts, timescale: 30, method: .roundTowardPositiveInfinity).value
        } else {
            try flush(until: pts, emit: emit)
        }
        latest = sample
        usedLatest = false
    }

    func flush(until end: CMTime, emit: (CMSampleBuffer) throws -> Void) throws {
        guard let sample = latest, end.isNumeric else { return }
        // A stalled machine must fail explicitly rather than allocate an unbounded backlog.
        guard end.seconds - Double(nextIndex) / 30 < 2 else {
            throw ProbeError.message("screen_encoder_overloaded")
        }
        while CMTime(value: nextIndex, timescale: 30) < end {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: nextIndex, timescale: 30), decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
            guard status == noErr, let copy = copy else { throw ProbeError.message("screen_retime_failed") }
            try emit(copy)
            if usedLatest { repeatedFrames += 1 }
            usedLatest = true
            nextIndex += 1
        }
    }
}

func captureDevices(_ kind: AVMediaType) -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) {
        types = kind == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
    } else {
        types = kind == .video ? [.builtInWideAngleCamera, .externalUnknown] : [.builtInMicrophone, .externalUnknown]
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes:types,mediaType:kind,position:.unspecified).devices
}

enum ProbeError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct RecordingPauseClock {
    private(set) var isPaused = false
    private var pausedAt = CMTime.invalid
    private var pausedDuration = CMTime.zero
    private var minimumAcceptedTime = CMTime.invalid

    mutating func pause(at time:CMTime) {
        guard !isPaused, time.isNumeric else { return }
        pausedAt = time; isPaused = true
    }

    mutating func resume(at time:CMTime) {
        guard isPaused, pausedAt.isNumeric, time.isNumeric else { return }
        pausedDuration = CMTimeAdd(pausedDuration,CMTimeMaximum(.zero,CMTimeSubtract(time,pausedAt)))
        pausedAt = .invalid; minimumAcceptedTime = time; isPaused = false
    }

    func accepts(_ time:CMTime) -> Bool {
        !isPaused && time.isNumeric && (!minimumAcceptedTime.isNumeric || time >= minimumAcceptedTime)
    }

    func outputTime(at time:CMTime,epoch:CMTime) -> CMTime {
        let effective = isPaused && pausedAt.isNumeric ? pausedAt : time
        return CMTimeSubtract(CMTimeSubtract(effective,epoch),pausedDuration)
    }
}

// Lifecycle is serialized by Recorder; setup completes before publishing the
// engine. Sample mutations use queue; stop drains it before finishing writers.
final class Engine: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "recordready.capture.samples")
    let setupQueue = DispatchQueue(label: "recordready.capture.capture")
    let session = AVCaptureSession()
    var stream: SCStream?
    var screenFile: VideoFile?, cameraFile: VideoFile?
    var epoch = CMTime.zero
    var recording = false
    var configured = false
    var cameraEnabled = true
    var microphoneEnabled = true
    var cameraID = ""
    var microphoneID = ""
    var directory: URL?
    var fatalError: String?
    var metadata: [String: Any] = [:]
    var onFailure: ((String) -> Void)?
    var latestAudioLevel = 0.0
    var logHandle: FileHandle?
    var loggedCounts: [String: Int] = [:]
    var observers: [NSObjectProtocol] = []
    var screenPacer = ScreenFramePacer()
    var pacingTimer: DispatchSourceTimer?
    var pauseClock = RecordingPauseClock()

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configureDevices() throws {
        if configured { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration() }
        for (enabled, kind) in [(cameraEnabled, AVMediaType.video), (microphoneEnabled, AVMediaType.audio)] {
            guard enabled else { continue }
            let selectedID = kind == .video ? cameraID : microphoneID
            let device = selectedID.isEmpty ? AVCaptureDevice.default(for: kind) : captureDevices( kind).first(where: { $0.uniqueID == selectedID })
            guard let device = device, device.isConnected else { throw ProbeError.message("device_missing") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ProbeError.message("device_unavailable") }
            session.addInput(input)
            let output: AVCaptureOutput
            if kind == .video {
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                video.setSampleBufferDelegate(self, queue: queue)
                output = video
                metadata["cameraDevice"] = device.localizedName
            } else {
                let audio = AVCaptureAudioDataOutput()
                audio.setSampleBufferDelegate(self, queue: queue)
                output = audio
                metadata["microphone"] = device.localizedName
            }
            guard session.canAddOutput(output) else { throw ProbeError.message("device_unavailable") }
            session.addOutput(output)
        }
        configured = true
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self = self else { return }
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "device_unavailable"
            self.queue.async { if self.recording { self.fail(ProbeError.message(message)) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self = self, let device = note.object as? AVCaptureDevice else { return }
            self.queue.async {
                if self.recording && self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).contains(where: { $0.device.uniqueID == device.uniqueID }) {
                    self.fail(ProbeError.message("device_missing"))
                }
            }
        })
    }

    @MainActor func start(displayID: CGDirectDisplayID, rectangle: CGRect, outputWidth: Int, outputHeight: Int) async throws {
        guard session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).allSatisfy({ $0.device.isConnected }) else { throw ProbeError.message("device_missing") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ProbeError.message("display_missing")
        }
        guard let currentApp = content.applications.first(where: { $0.processID == getpid() }) else {
            throw ProbeError.message("找不到当前应用，无法保证浮窗排除")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [currentApp], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = outputWidth; config.height = outputHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.sourceRect = rectangle
        config.showsCursor = true
        config.capturesAudio = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        let folder = artifacts.appendingPathComponent("Session-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + String(UUID().uuidString.prefix(6)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        let cameraInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })
        let cameraDimensions = cameraInput.map { CMVideoFormatDescriptionGetDimensions($0.device.activeFormat.formatDescription) }
        screenFile = try VideoFile(directory: folder, name: "screen", width: outputWidth, height: outputHeight, includeAudio: microphoneEnabled)
        if let dimensions = cameraDimensions {
            cameraFile = try VideoFile(directory: folder, name: "camera", width: Int(dimensions.width), height: Int(dimensions.height), includeAudio: microphoneEnabled)
        }
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
        metadata["outputPixels"] = [outputWidth, outputHeight]
        metadata["cameraOutputPixels"] = cameraDimensions.map { [$0.width, $0.height] } ?? []
        metadata["excludedApplicationPID"] = getpid()
        metadata["framework"] = "Tauri + ScreenCaptureKit + AVFoundation"
        metadata["startedAt"] = ISO8601DateFormatter().string(from: Date())
        metadata["state"] = "preparing"
        jsonWrite(metadata, folder.appendingPathComponent("session.json"))
        // Run both producers before opening the recording gate. The same host-clock epoch
        // applies to all streams; each sample is converted from its actual source clock.
        try await newStream.startCapture()
        queue.sync {
            epoch = CMClockGetTime(CMClockGetHostTimeClock())
            pauseClock = RecordingPauseClock()
            screenPacer = ScreenFramePacer()
            recording = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in
                guard let self = self, self.recording, !self.pauseClock.isPaused else { return }
                // Allow capture callbacks a small delivery margin; stop flushes the tail.
                let end = CMTimeSubtract(self.pauseClock.outputTime(at:CMClockGetTime(CMClockGetHostTimeClock()),epoch:self.epoch),CMTime(value:1,timescale:10))
                do { try self.screenPacer.flush(until: end) { try self.screenFile?.append($0, video: true, requireReady: true) } }
                catch { self.fail(error) }
            }
            pacingTimer = timer
            timer.resume()
        }
    }

    func normalized(_ sample: CMSampleBuffer, from clock: CMClock) throws -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        let hostPTS = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock())
        guard pauseClock.accepts(hostPTS) else { return nil }
        let pts = pauseClock.outputTime(at:hostPTS,epoch:epoch)
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
            timing[i].presentationTimeStamp = pauseClock.outputTime(at:CMSyncConvertTime(timing[i].presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()),epoch:epoch)
            if timing[i].decodeTimeStamp.isNumeric {
                timing[i].decodeTimeStamp = pauseClock.outputTime(at:CMSyncConvertTime(timing[i].decodeTimeStamp, from: clock, to: CMClockGetHostTimeClock()),epoch:epoch)
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
    func setPaused(_ paused:Bool) {
        queue.sync {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if paused { pauseClock.pause(at:now) }
            else { pauseClock.resume(at:now) }
        }
    }
    var elapsed:Double {
        queue.sync { max(0,pauseClock.outputTime(at:CMClockGetTime(CMClockGetHostTimeClock()),epoch:epoch).seconds) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard recording, !pauseClock.isPaused, type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        do {
            guard let clock = stream.synchronizationClock else { throw ProbeError.message("屏幕采集没有同步时钟") }
            if let sample = try normalized(sampleBuffer, from: clock) {
                try screenPacer.offer(sample) { try screenFile?.append($0, video: true, requireReady: true) }
                log("screen", sample: sample)
            }
        } catch { fail(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail(error) } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput, let channel = connection.audioChannels.first {
            latestAudioLevel = min(1, max(0, pow(10, Double(channel.averagePowerLevel) / 20)))
        }
        guard recording, !pauseClock.isPaused else { return }
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
    @MainActor func stop() async -> String {
        queue.sync {
            pacingTimer?.cancel(); pacingTimer = nil
            if recording {
                let end = pauseClock.outputTime(at:CMClockGetTime(CMClockGetHostTimeClock()),epoch:epoch)
                do { try screenPacer.flush(until:end) {
                    try screenFile?.append($0, video: true, requireReady: true)
                } } catch { fail(error) }
            }
            recording = false
        }
        if let stream = stream { try? await stream.stopCapture() }
        stream = nil
        guard let folder = directory else { return "尚无会话" }
        let a = await screenFile?.finish(in: folder) ?? "无屏幕文件"
        let b = await cameraFile?.finish(in: folder) ?? "not-requested"
        metadata["screen"] = screenFile?.summary()
        metadata["screenRepeatedFrames"] = screenPacer.repeatedFrames
        metadata["screenFrameRatePolicy"] = "constant-30-repeat-latest"
        metadata["recordingElapsed"] = pauseClock.outputTime(at:CMClockGetTime(CMClockGetHostTimeClock()),epoch:epoch).seconds
        metadata["camera"] = cameraFile?.summary()
        metadata["saveResults"] = ["screen": a, "camera": b]
        metadata["fatalError"] = fatalError as Any? ?? NSNull()
        metadata["state"] = a == "saved" && (b == "saved" || b == "not-requested") ? "saved" : "partial-or-failed"
        metadata["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        jsonWrite(metadata, folder.appendingPathComponent("session.json"))
        try? logHandle?.close(); logHandle = nil
        return "screen: \(a) · camera: \(b)\n\(folder.lastPathComponent)"
    }
}
