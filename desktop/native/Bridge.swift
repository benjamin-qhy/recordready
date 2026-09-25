import AppKit
import AVFoundation
import ScreenCaptureKit

// The C boundary copies requests immediately. Completion strings are borrowed only
// for the duration of the callback; Rust must copy them before returning.
typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

// AppKit's terminate: (menu, Command-Q and Dock) does not go through
// Tauri's event-loop exit request. Forward other delegate messages unchanged.
@MainActor final class QuitDelegate: NSObject, NSApplicationDelegate {
    let original: NSObject?
    let requested: () -> Void
    var allowed = false
    init(original: NSObject?, requested: @escaping () -> Void) {
        self.original = original; self.requested = requested
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowed { return .terminateNow }
        requested()
        return .terminateCancel
    }
}
@MainActor private var quitDelegate: QuitDelegate?
@_cdecl("rr_install_quit_guard")
@MainActor public func installQuitGuard(_ callback: @escaping @convention(c) () -> Void) {
    guard quitDelegate == nil else { return }
    let delegate = QuitDelegate(original: NSApplication.shared.delegate as? NSObject, requested: callback)
    quitDelegate = delegate
    NSApplication.shared.delegate = delegate
}
@_cdecl("rr_allow_quit")
@MainActor public func allowQuit() { quitDelegate?.allowed = true }

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class DragHandle: NSView {
    var anchor = CGPoint.zero
    var initial = CGPoint.zero
    var allowed: () -> Bool = { true }
    var moved: ((CGPoint) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard allowed() else { return }
        anchor = NSEvent.mouseLocation; initial = window?.frame.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowed() else { return }
        let p = NSEvent.mouseLocation
        moved?(CGPoint(x: initial.x + p.x - anchor.x, y: initial.y + p.y - anchor.y))
    }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedRed: 0.95, green: 0.39, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        for x in [bounds.midX - 8, bounds.midX, bounds.midX + 8] {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: bounds.midY - 1.5, width: 3, height: 3)).fill()
        }
    }
}

func previewFrame(in region:CGRect, layout:String, position:String, manual:CGPoint) -> CGRect {
    if layout == "fill" || region.isEmpty { return region }
    let padding = min(12,min(region.width,region.height)/8)
    let scale = min(1,min((region.width-2*padding)/224,(region.height-2*padding)/126))
    let size = CGSize(width:224*scale,height:126*scale)
    let x = position == "manual" ? max(0,min(1,manual.x)) : (position.hasSuffix("left") ? 0.0 : 1.0)
    let y = position == "manual" ? max(0,min(1,manual.y)) : (position.hasPrefix("top") ? 1.0 : 0.0)
    return CGRect(x:region.minX+padding+x*(region.width-size.width-2*padding),y:region.minY+padding+y*(region.height-size.height-2*padding),width:size.width,height:size.height)
}

final class PreviewDragView: DragHandle {
    override func draw(_ rect: NSRect) { NSColor.black.setFill(); bounds.fill() }
}

@MainActor final class Recorder: NSObject {
    static let shared = Recorder()
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        if let saved = preferences.dictionary(forKey: "recordingConfiguration"),
           let w = saved["width"] as? Int, let h = saved["height"] as? Int,
           w >= 240, w <= 3840, h >= 240, h <= 3840, w % 2 == 0, h % 2 == 0 {
            width = w; height = h
            camera = saved["camera"] as? Bool ?? true
            microphone = saved["microphone"] as? Bool ?? true
            cameraID = saved["cameraID"] as? String ?? ""
            microphoneID = saved["microphoneID"] as? String ?? ""
            displayID = (saved["displayID"] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            if let path = saved["directory"] as? String { artifacts = URL(fileURLWithPath: path, isDirectory: true) }
        }
        mirror = preferences.bool(forKey: "previewMirror")
        previewLayout = preferences.string(forKey: "previewLayout") ?? "small"
        previewPosition = preferences.string(forKey: "previewPosition") ?? "bottom-right"
        if let point = preferences.array(forKey:"previewManual") as? [Double], point.count == 2 { previewManual = CGPoint(x:point[0],y:point[1]) }
        let savedFont = preferences.double(forKey: "promptFont")
        if savedFont >= 24 && savedFont <= 48 { fontSize = savedFont }
        let savedSpeed = preferences.double(forKey: "promptSpeed")
        if savedSpeed > 0 && savedSpeed <= 100 { speed = savedSpeed }
    }
    var engine: Engine?
    var phase = "idle"
    var error = ""
    var width = 1080, height = 1920
    var camera = true, microphone = true
    var cameraID = "", microphoneID = ""
    var mirror = false, previewLayout = "small", previewPosition = "bottom-right"
    var previewManual = CGPoint(x:1,y:0)
    var previewLayer: AVCaptureVideoPreviewLayer?
    var overlaysVisible = false
    var promptStarted = false
    var uiCallback: ((String) -> Void)?
    var language = "zh-CN"
    var deviceCatalog: [String: Any] = [:]
    var catalogDate = Date.distantPast
    var startedAt: Date?
    var remaining = 0
    var generation = 0
    var result: [String: Any] = [:]
    var savedDirectory: URL?
    var frame: CapturePanel?, frameHandle: CapturePanel?, prompter: CapturePanel?, promptHandle: CapturePanel?, preview: CapturePanel?
    var corners: [CapturePanel] = []
    var promptText: NSTextView?
    var scroll: NSScrollView?
    var playing = false
    var speed = 24.0
    var fontSize = 32.0
    var timer: Timer?
    var region = CGRect.zero
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var screen: NSScreen { NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) ?? NSScreen.screens[0] }
    var locked: Bool { ["preparing", "countdown", "starting", "recording", "saving"].contains(phase) }

    func panel(_ rect: CGRect, passthrough: Bool) -> CapturePanel {
        let p = CapturePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.ignoresMouseEvents = passthrough
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.orderFrontRegardless()
        return p
    }

    func placeRegion() {
        let visible = screen.visibleFrame
        let h = min(visible.height - 180, 650)
        let w = h * Double(width) / Double(height)
        let scale = min(1, (visible.width - 160) / w)
        region = CGRect(x: visible.midX - w * scale / 2, y: visible.midY - h * scale / 2, width: w * scale, height: h * scale)
        updateFrame()
    }

    func updateFrame() {
        frame?.setFrame(region.insetBy(dx: -2, dy: -2), display: true)
        frameHandle?.setFrameOrigin(CGPoint(x: region.midX - 24, y: region.maxY + 2))
        let points = [CGPoint(x:region.minX,y:region.minY),CGPoint(x:region.maxX,y:region.minY),CGPoint(x:region.minX,y:region.maxY),CGPoint(x:region.maxX,y:region.maxY)]
        for (index, panel) in corners.enumerated() { panel.setFrameOrigin(CGPoint(x:points[index].x-7,y:points[index].y-7)) }
        layoutPreview()
    }

    func showOverlays() {
        overlaysVisible = true
        if frame == nil {
            frame = panel(.zero, passthrough: true)
            frame?.contentView?.wantsLayer = true
            frame?.contentView?.layer?.borderColor = NSColor.systemOrange.cgColor
            frame?.contentView?.layer?.borderWidth = 2
            frameHandle = panel(CGRect(x: 0, y: 0, width: 48, height: 18), passthrough: false)
            let handle = DragHandle(frame: CGRect(x: 0, y: 0, width: 48, height: 18))
            handle.allowed = { [weak self] in !(self?.locked ?? true) }
            handle.moved = { [weak self] point in
                guard let self = self else { return }
                let v = self.screen.visibleFrame
                let x = max(v.minX, min(point.x + 24 - self.region.width / 2, v.maxX - self.region.width))
                let y = max(v.minY, min(point.y - self.region.height - 2, v.maxY - self.region.height - 24))
                self.region.origin = CGPoint(x: x, y: y)
                self.updateFrame()
            }
            frameHandle?.contentView = handle
            for index in 0..<4 {
                let corner = panel(CGRect(x:0,y:0,width:14,height:14),passthrough:false)
                let control = DragHandle(frame:CGRect(x:0,y:0,width:14,height:14))
                control.allowed = { [weak self] in !(self?.locked ?? true) }
                control.moved = { [weak self] point in
                    guard let self = self else { return }
                    let left = index % 2 == 0, bottom = index < 2
                    let anchor = CGPoint(x:left ? self.region.maxX:self.region.minX,y:bottom ? self.region.maxY:self.region.minY)
                    let ratio = CGFloat(self.width)/CGFloat(self.height), visible = self.screen.visibleFrame
                    let maxW = min(left ? anchor.x-visible.minX:visible.maxX-anchor.x,(bottom ? anchor.y-visible.minY:visible.maxY-anchor.y-24)*ratio)
                    let newW = min(maxW,max(120,abs(point.x+7-anchor.x)))
                    let newH = newW/ratio
                    self.region = CGRect(x:left ? anchor.x-newW:anchor.x,y:bottom ? anchor.y-newH:anchor.y,width:newW,height:newH)
                    self.updateFrame()
                }
                corner.contentView = control; corners.append(corner)
            }
            placeRegion()
            let body = CGRect(x: region.midX - 320, y: region.maxY - 240, width: 640, height: 200)
            prompter = panel(body, passthrough: true)
            let sc = NSScrollView(frame: CGRect(origin: .zero, size: body.size))
            sc.drawsBackground = true; sc.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            sc.wantsLayer = true; sc.layer?.cornerRadius = 14
            let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
            text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
            text.textColor = .white; text.font = .systemFont(ofSize: fontSize)
            text.textContainerInset = NSSize(width: 20, height: 20)
            text.textContainer?.widthTracksTextView = true
            text.isVerticallyResizable = true
            text.string = preferences.string(forKey: "script") ?? ""
            sc.documentView = text; prompter?.contentView = sc
            promptText = text; scroll = sc
            promptHandle = panel(CGRect(x: body.midX - 36, y: body.maxY, width: 72, height: 20), passthrough: false)
            let ph = DragHandle(frame: CGRect(x: 0, y: 0, width: 72, height: 20))
            ph.moved = { [weak self] point in
                guard let self = self else { return }
                let v = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) })?.visibleFrame ?? self.screen.visibleFrame
                let x = max(v.minX+16,min(point.x+36-320,v.maxX-656))
                let y = max(v.minY+(self.language == "en" ? 112 : 80),min(point.y-200,v.maxY-236))
                self.promptHandle?.setFrameOrigin(CGPoint(x:x+284,y:y+200))
                self.prompter?.setFrameOrigin(CGPoint(x:x,y:y))
            }
            promptHandle?.contentView = ph
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.playing, let sc = self.scroll, let text = self.promptText else { return }
                    let maxY = max(0, text.bounds.height - sc.contentView.bounds.height)
                    let y = min(maxY, sc.contentView.bounds.origin.y + self.speed / 30)
                    sc.contentView.scroll(to: CGPoint(x: 0, y: y)); sc.reflectScrolledClipView(sc.contentView)
                    if y >= maxY { self.playing = false }
                }
            }
        }
        for p in [frame, frameHandle, prompter, promptHandle] { p?.orderFrontRegardless() }
        corners.forEach { $0.orderFrontRegardless() }
        if camera, let engine = engine {
            if preview == nil {
                preview = panel(CGRect(x: region.maxX - 240, y: region.minY + 14, width: 224, height: 126), passthrough: false)
                let handle = PreviewDragView(frame: CGRect(x:0,y:0,width:224,height:126))
                handle.moved = { [weak self] point in
                    guard let self = self else { return }
                    self.previewPosition = "manual"
                    self.preferences.set("manual", forKey: "previewPosition")
                    let size = self.preview?.frame.size ?? .zero
                    let padding = min(12,min(self.region.width,self.region.height)/8)
                    let availableX = max(1,self.region.width-size.width-2*padding), availableY = max(1,self.region.height-size.height-2*padding)
                    self.previewManual = CGPoint(x:max(0,min(1,(point.x-self.region.minX-padding)/availableX)),y:max(0,min(1,(point.y-self.region.minY-padding)/availableY)))
                    self.preferences.set([self.previewManual.x,self.previewManual.y],forKey:"previewManual")
                    self.layoutPreview()
                }
                preview?.contentView = handle
                handle.wantsLayer = true
                handle.layer?.backgroundColor = NSColor.black.cgColor
                handle.layer?.cornerRadius = 16
                handle.layer?.masksToBounds = true
                let gear = NSButton(image: NSImage(systemSymbolName:"gearshape",accessibilityDescription:"Camera settings")!, target:self, action:#selector(cameraSettings))
                gear.frame = CGRect(x:180,y:84,width:36,height:36)
                gear.setAccessibilityLabel(language == "zh-CN" ? "摄像头设置" : "Camera settings")
                gear.autoresizingMask = [.minXMargin, .minYMargin]
                gear.bezelStyle = .regularSquare
                handle.addSubview(gear)
            }
            previewLayer?.removeFromSuperlayer()
            let layer = AVCaptureVideoPreviewLayer(session: engine.session)
            previewLayer = layer
            preview?.contentView?.layer?.insertSublayer(layer, at:0)
            layoutPreview()
            if let frame = frame { preview?.order(.below, relativeTo:frame.windowNumber) }
            else { preview?.orderFrontRegardless() }
        } else { preview?.orderOut(nil) }
    }

    @objc func cameraSettings() { uiCallback?("camera") }

    func layoutPreview() {
        guard let preview = preview else { return }
        let rect = previewFrame(in:region,layout:previewLayout,position:previewPosition,manual:previewManual)
        let size = rect.size
        preview.setFrame(rect,display:true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer?.frame = CGRect(origin:.zero,size:size)
        previewLayer?.videoGravity = previewLayout == "fill" ? .resizeAspectFill : .resizeAspect
        if let connection = previewLayer?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }
        CATransaction.commit()
    }

    func refreshDevices() {
        guard Date().timeIntervalSince(catalogDate) > 2 else { return }
        catalogDate = Date()
        deviceCatalog = ["cameras":captureDevices(.video).map { ["id":$0.uniqueID,"name":$0.localizedName] },
                         "microphones":captureDevices(.audio).map { ["id":$0.uniqueID,"name":$0.localizedName] },
                         "displays":NSScreen.screens.map { ["id":String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0),"name":$0.localizedName] }]
    }

    // Global logical top-left coordinates shared with Tauri, including secondary displays.
    func uiRect(_ rect: CGRect) -> [Double] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return [rect.minX,top-rect.maxY,rect.width,rect.height]
    }

    func snapshot() -> [String: Any] {
        refreshDevices()
        let details = engine?.metadata ?? [:]
        let body = prompter?.frame ?? .zero
        let toolbarHeight: CGFloat = language == "en" ? 96 : 64
        let promptBar = CGRect(x:body.minX,y:body.minY-toolbarHeight,width:body.width,height:toolbarHeight)
        let sizeBar = CGRect(x:region.midX-160,y:region.maxY+28,width:320,height:48)
        return ["phase": phase, "error": error, "remaining": remaining,
                "elapsed": startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0,
                "width": width, "height": height, "camera": camera, "microphone": microphone,
                "catalog":deviceCatalog,"cameraID":cameraID,"microphoneID":microphoneID,"displayID":String(displayID),
                "mirror":mirror,"previewLayout":previewLayout,"previewPosition":previewPosition,"promptStarted":promptStarted,
                "overlaysVisible":overlaysVisible,"promptToolbar":uiRect(promptBar),"regionToolbar":uiRect(sizeBar),
                "cameraAnchor":uiRect(preview?.frame ?? region),"visibleFrame":uiRect(screen.visibleFrame),"promptVisibleFrame":uiRect(prompter?.screen?.visibleFrame ?? screen.visibleFrame),
                "playing": playing, "fontSize": fontSize, "promptSpeed": speed, "directory": artifacts.path, "result": result,
                "level": microphone ? (engine?.queue.sync { engine?.latestAudioLevel ?? 0 } ?? 0) : 0,
                "devices": ["camera": details["cameraDevice"] ?? "", "microphone": details["microphone"] ?? ""],
                "region": [region.origin.x, region.origin.y, region.width, region.height]]
    }

    func prepare() async throws {
        guard !locked else { throw ProbeError.message("session_busy") }
        phase = "preparing"; error = ""
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw ProbeError.message("screen_permission") }
            if camera { guard await AVCaptureDevice.requestAccess(for: .video) else { throw ProbeError.message("camera_permission") } }
            if microphone { guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ProbeError.message("microphone_permission") } }
            if let old = engine {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in old.setupQueue.async { old.session.stopRunning(); c.resume() } }
            }
            guard NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { throw ProbeError.message("display_missing") }
            let e = Engine(); e.cameraEnabled = camera; e.microphoneEnabled = microphone
            e.cameraID = cameraID; e.microphoneID = microphoneID
            let needsSession = camera || microphone
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                e.setupQueue.async {
                    do { try e.configureDevices(); if needsSession { e.session.startRunning() }; c.resume() }
                    catch { c.resume(throwing: error) }
                }
            }
            engine = e
            e.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.error = message
                    if self.phase == "recording" || self.phase == "starting" { await self.stop() }
                }
            }
            showOverlays(); phase = "ready"
        } catch { phase = "idle"; self.error = error.localizedDescription; throw error }
    }

    func start() async throws {
        guard phase == "ready", let engine = engine else { throw ProbeError.message("not_ready") }
        generation += 1; let token = generation
        result = [:]; error = ""; phase = "countdown"; remaining = 3
        for value in (1...3).reversed() {
            remaining = value
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard generation == token else { return }
        }
        remaining = 0; phase = "starting"
        // AppKit origin is lower-left; ScreenCaptureKit sourceRect is display-local top-left.
        let source = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
        do {
            try await engine.start(displayID: displayID, rectangle: source, outputWidth: width, outputHeight: height)
            startedAt = Date(); phase = "recording"
        } catch {
            self.error = error.localizedDescription
            await stop()
            throw error
        }
    }

    func stop() async {
        guard ["starting", "recording"].contains(phase), let e = engine else { return }
        phase = "saving"; playing = false
        _ = await e.stop()
        result = e.metadata
        savedDirectory = e.directory
        let statuses = (result["saveResults"] as? [String: String] ?? [:]).values.filter { $0 != "not-requested" }
        let saved = statuses.filter { $0 == "saved" }.count
        phase = !statuses.isEmpty && saved == statuses.count ? "saved" : saved > 0 ? "partial" : "failed"
        startedAt = nil
    }

    func request(_ data: [String: Any]) async throws -> [String: Any] {
        switch data["action"] as? String {
        case "status": break
        case "interface":
            language = data["language"] as? String ?? language
            if let gear = preview?.contentView?.subviews.first as? NSButton { gear.setAccessibilityLabel(language == "zh-CN" ? "摄像头设置" : "Camera settings") }
        case "prepare": try await prepare()
        case "start": try await start()
        case "stop": await stop()
        case "cancel": if phase == "countdown" { generation += 1; phase = "ready"; remaining = 0 }
        case "configure":
            let restorePreview = phase == "ready"
            guard !locked else { throw ProbeError.message("session_busy") }
            let w = data["width"] as? Int ?? width, h = data["height"] as? Int ?? height
            guard w >= 240, h >= 240, w <= 3840, h <= 3840, w % 2 == 0, h % 2 == 0 else { throw ProbeError.message("invalid_size") }
            let nextCamera = data["cameraID"] as? String ?? cameraID
            let nextMicrophone = data["microphoneID"] as? String ?? microphoneID
            // Explicit selections never silently fall back to another device.
            for (key, id, kind) in [("cameraID",nextCamera,AVMediaType.video),("microphoneID",nextMicrophone,AVMediaType.audio)] {
                if data[key] != nil && !id.isEmpty && !captureDevices(kind).contains(where: { $0.uniqueID == id }) { throw ProbeError.message("device_missing") }
            }
            let nextDisplay = (data["displayID"] as? String).flatMap(UInt32.init) ?? displayID
            if data["displayID"] != nil && !NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == nextDisplay }) { throw ProbeError.message("display_missing") }
            if let path = data["directory"] as? String {
                guard FileManager.default.isWritableFile(atPath: path) else { throw ProbeError.message("directory_unwritable") }
                artifacts = URL(fileURLWithPath: path, isDirectory: true)
            }
            let relocate = w != width || h != height || nextDisplay != displayID
            width = w; height = h
            cameraID = nextCamera; microphoneID = nextMicrophone; displayID = nextDisplay
            camera = data["camera"] as? Bool ?? camera
            microphone = data["microphone"] as? Bool ?? microphone
            preferences.set(["width":width,"height":height,"camera":camera,"microphone":microphone,"directory":artifacts.path,"cameraID":cameraID,"microphoneID":microphoneID,"displayID":displayID], forKey: "recordingConfiguration")
            phase = "preparing"
            if let old = engine {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in old.setupQueue.async { old.session.stopRunning(); c.resume() } }
            }
            preview?.orderOut(nil)
            engine = nil
            phase = "idle"
            if relocate { placeRegion() }
            if restorePreview { try await prepare() }
        case "preview":
            let layout = data["layout"] as? String ?? previewLayout
            let position = data["position"] as? String ?? previewPosition
            guard ["small","fill"].contains(layout), ["top-left","top-right","bottom-left","bottom-right","manual"].contains(position) else { throw ProbeError.message("invalid_preview") }
            mirror = data["mirror"] as? Bool ?? mirror
            previewLayout = layout; previewPosition = position
            preferences.set(mirror,forKey:"previewMirror"); preferences.set(layout,forKey:"previewLayout"); preferences.set(position,forKey:"previewPosition")
            layoutPreview()
        case "script":
            guard !locked else { throw ProbeError.message("session_busy") }
            let text = data["text"] as? String ?? ""
            preferences.set(text, forKey: "script")
            promptText?.string = text
        case "prompt":
            if let play = data["playing"] as? Bool { playing = play; if play { promptStarted = true } }
            if data["reset"] as? Bool == true { playing = false; promptStarted = false; scroll?.contentView.scroll(to: .zero) }
            if let size = data["fontSize"] as? Double, size >= 24, size <= 48 {
                fontSize = size; promptText?.font = .systemFont(ofSize: size)
                preferences.set(size, forKey: "promptFont")
            }
            if let rate = data["speed"] as? Double, rate > 0, rate <= 100 {
                speed = rate; preferences.set(rate, forKey: "promptSpeed")
            }
        case "open-folder": NSWorkspace.shared.open(savedDirectory ?? artifacts)
        case "hide":
            guard !locked else { throw ProbeError.message("session_busy") }
            overlaysVisible = false
            for p in [frame, frameHandle, prompter, promptHandle, preview] { p?.orderOut(nil) }
            corners.forEach { $0.orderOut(nil) }
        default: throw ProbeError.message("unknown_action")
        }
        return snapshot()
    }
}

@_cdecl("rr_request")
public func rrRequest(_ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?, _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void) {
    let request = String(cString: json)
    Task { @MainActor in
        let response: [String: Any]
        do {
            guard let data = request.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeError.message("invalid_request") }
            response = ["ok": true, "value": try await Recorder.shared.request(value)]
        } catch { response = ["ok": false, "error": error.localizedDescription] }
        let bytes = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        String(decoding: bytes, as: UTF8.self).withCString { callback(context, $0) }
    }
}

@_cdecl("rr_install_ui_callback")
@MainActor public func installUICallback(_ callback: @escaping @convention(c) (UnsafePointer<CChar>) -> Void) {
    Recorder.shared.uiCallback = { name in name.withCString { callback($0) } }
}
