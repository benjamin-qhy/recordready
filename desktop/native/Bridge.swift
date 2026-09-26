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
    var coversFullDisplay = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        coversFullDisplay ? frameRect : super.constrainFrameRect(frameRect,to:screen)
    }
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
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
        anchor = window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow; initial = window?.frame.origin ?? .zero
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowed() else { return }
        let p = window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow
        moved?(CGPoint(x: initial.x + p.x - anchor.x, y: initial.y + p.y - anchor.y))
    }
    override func mouseUp(with event:NSEvent) { NSCursor.openHand.set() }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
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

func clampedOverlay(_ rect:CGRect, bounds:CGRect, minimum:CGSize = .zero) -> CGRect {
    let width = min(bounds.width,max(minimum.width,rect.width)), height = min(bounds.height,max(minimum.height,rect.height))
    return CGRect(x:max(bounds.minX,min(rect.minX,bounds.maxX-width)),y:max(bounds.minY,min(rect.minY,bounds.maxY-height)),width:width,height:height)
}

func regionToolbarPlacement(region:CGRect,size:CGSize,visibleFrames:[CGRect],gap:CGFloat = 12) -> (frame:CGRect,visibleFrame:CGRect) {
    let orderedFrames = visibleFrames.isEmpty ? [region] : visibleFrames
    for (index,visible) in orderedFrames.enumerated() {
        if index > 0 {
            let frame = CGRect(x:visible.midX-size.width/2,y:visible.maxY-size.height,width:size.width,height:size.height)
            if visible.contains(frame) && !frame.intersects(region) { return (frame,visible) }
            continue
        }
        let centeredX = max(visible.minX,min(region.midX-size.width/2,visible.maxX-size.width))
        let centeredY = max(visible.minY,min(region.midY-size.height/2,visible.maxY-size.height))
        let candidates = [
            CGRect(x:centeredX,y:region.maxY+gap,width:size.width,height:size.height),
            CGRect(x:region.minX-size.width-gap,y:centeredY,width:size.width,height:size.height),
            CGRect(x:region.maxX+gap,y:centeredY,width:size.width,height:size.height),
            CGRect(x:centeredX,y:region.minY-size.height-gap,width:size.width,height:size.height)
        ]
        if let frame = candidates.first(where:{ visible.contains($0) && !$0.intersects(region) }) { return (frame,visible) }
    }
    let visible = orderedFrames[0]
    let frame = CGRect(x:max(visible.minX,min(region.midX-size.width/2,visible.maxX-size.width)),y:visible.maxY-size.height,width:size.width,height:size.height)
    return (frame,visible)
}

func resizedOverlay(_ initial:CGRect, edge:String, delta:CGPoint, bounds:CGRect, minimum:CGSize) -> CGRect {
    var left = initial.minX, right = initial.maxX, bottom = initial.minY, top = initial.maxY
    let minWidth = min(minimum.width,bounds.width), minHeight = min(minimum.height,bounds.height)
    if edge.contains("-") {
        let moveLeft = edge.contains("left"), moveBottom = edge.contains("bottom")
        let anchor = CGPoint(x:moveLeft ? right:left,y:moveBottom ? top:bottom)
        let sx = (moveLeft ? -delta.x:delta.x)/initial.width, sy = (moveBottom ? -delta.y:delta.y)/initial.height
        let proposed = 1 + (abs(sx) > abs(sy) ? sx:sy)
        let maximum = min((moveLeft ? anchor.x-bounds.minX:bounds.maxX-anchor.x)/initial.width,(moveBottom ? anchor.y-bounds.minY:bounds.maxY-anchor.y)/initial.height)
        let scale = min(maximum,max(max(minWidth/initial.width,minHeight/initial.height),proposed))
        let width = initial.width*scale, height = initial.height*scale
        return CGRect(x:moveLeft ? anchor.x-width:anchor.x,y:moveBottom ? anchor.y-height:anchor.y,width:width,height:height)
    }
    if edge == "left" { left = max(bounds.minX,min(right-minWidth,left+delta.x)) }
    if edge == "right" { right = min(bounds.maxX,max(left+minWidth,right+delta.x)) }
    if edge == "bottom" { bottom = max(bounds.minY,min(top-minHeight,bottom+delta.y)) }
    if edge == "top" { top = min(bounds.maxY,max(bottom+minHeight,top+delta.y)) }
    return CGRect(x:left,y:bottom,width:right-left,height:top-bottom)
}

func resizedPrompt(_ initial:CGRect, edge:String, delta:CGPoint, bounds:CGRect) -> CGRect {
    resizedOverlay(initial,edge:edge,delta:delta,bounds:bounds,minimum:CGSize(width:320,height:120))
}

func resizedRegion(_ initial:CGRect, edge:String, delta:CGPoint, bounds:CGRect, width:Int, height:Int) -> (rect:CGRect,width:Int,height:Int) {
    let desired = resizedOverlay(initial,edge:edge,delta:delta,bounds:bounds,minimum:CGSize(width:80,height:80))
    if edge.contains("-") { return (desired,width,height) }
    let horizontal = ["left","right"].contains(edge)
    let ratioAxis = horizontal ? desired.width/initial.height : desired.height/initial.width
    let fixed = horizontal ? height : width
    let maximumGeometry = horizontal ? (edge == "left" ? initial.maxX-bounds.minX:bounds.maxX-initial.minX) : (edge == "bottom" ? initial.maxY-bounds.minY:bounds.maxY-initial.minY)
    let fixedGeometry = horizontal ? initial.height : initial.width
    let maximumOutput = min(3840,Int(floor(maximumGeometry/fixedGeometry*Double(fixed)/2))*2)
    guard maximumOutput >= 240 else { return (initial,width,height) }
    let output = max(240,min(maximumOutput,Int((ratioAxis*Double(fixed)/2).rounded())*2))
    let length = fixedGeometry*Double(output)/Double(fixed)
    let rect = horizontal ? CGRect(x:edge == "left" ? initial.maxX-length:initial.minX,y:initial.minY,width:length,height:initial.height) : CGRect(x:initial.minX,y:edge == "bottom" ? initial.maxY-length:initial.minY,width:initial.width,height:length)
    return (rect,horizontal ? output:width,horizontal ? height:output)
}

func savedRect(_ value:Any?) -> CGRect? {
    guard let a = value as? [Double], a.count == 4, a.allSatisfy({ $0.isFinite }), a[2] > 0, a[3] > 0 else { return nil }
    return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])
}

func monitoringDevices(camera:Bool,microphone:Bool,cameraAuthorized:Bool,microphoneAuthorized:Bool) -> [Bool] {
    [camera && cameraAuthorized,microphone && microphoneAuthorized]
}

func resizeCursor(_ edge:String) -> NSCursor {
    guard edge.contains("-") else { return ["left","right"].contains(edge) ? .resizeLeftRight:.resizeUpDown }
    let image = NSImage(size:NSSize(width:20,height:20),flipped:false) { rect in
        let rising = ["bottom-left","top-right"].contains(edge)
        let path = NSBezierPath()
        let a = CGPoint(x:4,y:rising ? 4:16), b = CGPoint(x:16,y:rising ? 16:4)
        path.move(to:a); path.line(to:b)
        path.move(to:CGPoint(x:a.x,y:a.y+(rising ? 5:-5))); path.line(to:a); path.line(to:CGPoint(x:a.x+5,y:a.y))
        path.move(to:CGPoint(x:b.x-5,y:b.y)); path.line(to:b); path.line(to:CGPoint(x:b.x,y:b.y+(rising ? -5:5)))
        NSColor.white.setStroke(); path.lineWidth = 3; path.stroke()
        NSColor.black.setStroke(); path.lineWidth = 1.2; path.stroke(); return true
    }
    return NSCursor(image:image,hotSpot:NSPoint(x:10,y:10))
}

final class PromptResizeView: NSView {
    var edge = ""
    var initial = CGRect.zero, anchor = CGPoint.zero
    var body: () -> CGRect = { .zero }
    var allowed: () -> Bool = { true }
    var resized: ((CGRect,String,CGPoint) -> Void)?
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) { guard allowed() else { return }; initial = body(); anchor = window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow; resizeCursor(edge).set() }
    override func mouseDragged(with event:NSEvent) {
        guard allowed() else { return }
        let point = window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow
        resized?(initial,edge,CGPoint(x:point.x-anchor.x,y:point.y-anchor.y))
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor:resizeCursor(edge))
    }
    override func draw(_ rect:NSRect) {
        NSColor(calibratedWhite:0.55,alpha:0.6).setStroke()
        let grip = NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:2,yRadius:2)
        grip.lineWidth = 0.6; grip.stroke()
    }
}

func promptDragExceeded(_ delta:CGPoint) -> Bool { hypot(delta.x,delta.y) > 5 }
func promptEventPoint(_ location:CGPoint, windowOrigin:CGPoint) -> CGPoint {
    CGPoint(x:windowOrigin.x+location.x,y:windowOrigin.y+location.y)
}

final class PromptClipView: NSClipView { override var isOpaque:Bool { false } }

final class PromptScrollView: NSScrollView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        // Keep a virtually transparent hit surface when the requested background
        // is fully clear; text, border, and native controls retain their opacity.
        NSColor.white.withAlphaComponent(0.001).setFill(); dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

final class PromptTextView: NSTextView {
    override var isOpaque:Bool { false }
    var interactionBegan: (() -> Void)?
    var moved: ((CGPoint) -> Void)?
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func mouseDown(with event:NSEvent) {
        interactionBegan?()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        let initial = window?.frame.origin ?? .zero
        let anchor = promptEventPoint(event.locationInWindow,windowOrigin:initial)
        var dragged = false
        // Track the gesture before handing a click to NSTextView. Requeue its
        // matching mouse-up so AppKit retains native caret and double-click behavior.
        while let next = window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {
                if !dragged { NSApplication.shared.postEvent(next,atStart:true); super.mouseDown(with:event) }
                NSCursor.openHand.set()
                break
            }
            // Event coordinates retain each queued gesture sample; the global mouse
            // position may already be at mouse-up when automation delivers the down.
            let point = promptEventPoint(next.locationInWindow,windowOrigin:window?.frame.origin ?? initial)
            let delta = CGPoint(x:point.x-anchor.x,y:point.y-anchor.y)
            dragged = dragged || promptDragExceeded(delta)
            if dragged { NSCursor.closedHand.set(); moved?(CGPoint(x:initial.x+delta.x,y:initial.y+delta.y)) }
        }
    }
}

final class RegionDragView: DragHandle {
    override func draw(_ rect: NSRect) { NSColor.white.withAlphaComponent(0.001).setFill(); bounds.fill() }
}

func previewOutline(_ rect:CGRect, circular:Bool) -> CGPath {
    circular ? CGPath(ellipseIn:rect,transform:nil) : CGPath(roundedRect:rect,cornerWidth:12,cornerHeight:12,transform:nil)
}

func linkedFillDrag(layout:String,overlaysVisible:Bool,previewOrigin:CGPoint) -> CGPoint? {
    layout == "fill" && overlaysVisible ? previewOrigin : nil
}

final class PreviewDragView: DragHandle {
    var circular = false { didSet { needsDisplay = true } }
    override var isOpaque:Bool { false }
    override func draw(_ rect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(previewOutline(bounds,circular:circular));context.setFillColor(NSColor.black.cgColor);context.fillPath()
    }
}

@MainActor final class Recorder: NSObject, NSTextViewDelegate {
    static let shared = Recorder()
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        theme = NSApplication.shared.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? "dark" : "light"
        if let savedOpacity = preferences.object(forKey:"promptOpacity") as? Double, savedOpacity.isFinite, (0...1).contains(savedOpacity) { promptOpacity = savedOpacity }
        if let saved = preferences.dictionary(forKey: "recordingConfiguration"),
           let w = saved["width"] as? Int, let h = saved["height"] as? Int,
           w >= 240, w <= 3840, h >= 240, h <= 3840, w % 2 == 0, h % 2 == 0 {
            width = w; height = h
            camera = saved["camera"] as? Bool ?? false
            microphone = saved["microphone"] as? Bool ?? false
            cameraID = saved["cameraID"] as? String ?? ""
            microphoneID = saved["microphoneID"] as? String ?? ""
            displayID = (saved["displayID"] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            if let path = saved["directory"] as? String { artifacts = URL(fileURLWithPath: path, isDirectory: true) }
        }
        mirror = preferences.bool(forKey: "previewMirror")
        previewLayout = preferences.string(forKey: "previewLayout") ?? "small"
        previewShape = preferences.string(forKey:"previewShape") == "circle" ? "circle" : "square"
        previewPosition = preferences.string(forKey: "previewPosition") ?? "bottom-right"
        if let point = preferences.array(forKey:"previewManual") as? [Double], point.count == 2 { previewManual = CGPoint(x:point[0],y:point[1]) }
        let savedFont = preferences.double(forKey: "promptFont")
        if savedFont >= 24 && savedFont <= 48 { fontSize = savedFont }
        let savedSpeed = preferences.double(forKey: "promptSpeed")
        if savedSpeed >= 2 && savedSpeed <= 100 { speed = savedSpeed }
        if !NSScreen.screens.contains(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) { displayID = CGMainDisplayID() }
        overlaysVisible = preferences.bool(forKey:"regionVisible")
        promptVisible = preferences.bool(forKey:"promptVisible")
        if let saved = savedRect(preferences.array(forKey:"regionFrame")) {
            let bounds = screen.visibleFrame
            let scale = min(1,min(bounds.width/saved.width,bounds.height/saved.height))
            region = clampedOverlay(CGRect(origin:saved.origin,size:CGSize(width:saved.width*scale,height:saved.height*scale)),bounds:bounds)
            if abs(region.width/region.height-Double(width)/Double(height)) > 0.001 { region = .zero }
        }
        if let saved = savedRect(preferences.array(forKey:"promptFrame")) {
            let visible = bestScreen(for:saved).visibleFrame
            let toolbar = promptToolbarHeight(min(saved.width,visible.width-16))
            storedPromptFrame = clampedOverlay(saved,bounds:CGRect(x:visible.minX+8,y:visible.minY+toolbar,width:visible.width-16,height:visible.height-toolbar-8),minimum:CGSize(width:320,height:120))
        }
        if let saved = savedRect(preferences.array(forKey:"cameraFrame")) {
            previewRect = clampedOverlay(saved,bounds:bestScreen(for:saved).visibleFrame.insetBy(dx:8,dy:8),minimum:CGSize(width:120,height:80))
        }
    }
    var engine: Engine?
    var cameraAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for:.video) }
    var microphoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for:.audio) }
    var monitorError = ""
    var monitorObservers: [NSObjectProtocol] = []
    var restoredSession = false
    var storedPromptFrame: CGRect?
    var previewRect = CGRect.zero
    var previewResizers: [CapturePanel] = []
    var phase = "idle" { didSet { updateInteraction() } }
    var error = ""
    var width = 1080, height = 1920
    var camera = false, microphone = false
    var cameraID = "", microphoneID = ""
    var mirror = false, previewShape = "square", previewLayout = "small", previewPosition = "bottom-right"
    var previewManual = CGPoint(x:1,y:0)
    var previewLayer: AVCaptureVideoPreviewLayer?
    var overlaysVisible = false
    var promptStarted = false
    var promptVisible = false
    var uiCallback: ((String) -> Void)?
    var language = "zh-CN"
    var theme = "light"
    var promptOpacity = 1.0
    var deviceCatalog: [String: Any] = [:]
    var catalogDate = Date.distantPast
    var startedAt: Date?
    var remaining = 0
    var generation = 0
    var result: [String: Any] = [:]
    var savedDirectory: URL?
    var frame: CapturePanel?, frameHandle: CapturePanel?, prompter: CapturePanel?, preview: CapturePanel?
    var corners: [CapturePanel] = []
    var shades: [CapturePanel] = []
    var promptResizers: [CapturePanel] = []
    var promptText: NSTextView?
    var scroll: NSScrollView?
    var playing = false
    var speed = 24.0
    var fontSize = 32.0
    var timer: Timer?
    var region = CGRect.zero
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var screen: NSScreen { NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) ?? NSScreen.screens[0] }
    var locked: Bool { ["preparing", "countdown", "starting", "recording", "paused", "saving"].contains(phase) }

    func bestScreen(for rect:CGRect) -> NSScreen {
        NSScreen.screens.max(by: { a,b in
            let ar = a.visibleFrame.intersection(rect), br = b.visibleFrame.intersection(rect)
            return (ar.isNull ? 0:ar.width*ar.height) < (br.isNull ? 0:br.width*br.height)
        }).flatMap { $0.visibleFrame.intersects(rect) ? $0:nil } ?? screen
    }

    func persistLayout() {
        preferences.set(overlaysVisible,forKey:"regionVisible")
        preferences.set(promptVisible,forKey:"promptVisible")
        if !region.isEmpty { preferences.set([region.minX,region.minY,region.width,region.height],forKey:"regionFrame") }
        if let rect = prompter?.frame { preferences.set([rect.minX,rect.minY,rect.width,rect.height],forKey:"promptFrame") }
        if !previewRect.isEmpty { preferences.set([previewRect.minX,previewRect.minY,previewRect.width,previewRect.height],forKey:"cameraFrame") }
    }

    func persistConfiguration() {
        preferences.set(["width":width,"height":height,"camera":camera,"microphone":microphone,"directory":artifacts.path,"cameraID":cameraID,"microphoneID":microphoneID,"displayID":displayID],forKey:"recordingConfiguration")
    }

    func panel(_ rect: CGRect, passthrough: Bool) -> CapturePanel {
        let p = CapturePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.ignoresMouseEvents = passthrough
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
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

    func updateInteraction() {
        frame?.ignoresMouseEvents = locked
        corners.forEach { $0.ignoresMouseEvents = locked }
        updateShades()
        updatePromptInteraction()
    }

    func moveRegion(_ origin: CGPoint) {
        let v = screen.visibleFrame
        region.origin = CGPoint(x:max(v.minX,min(origin.x,v.maxX-region.width)),y:max(v.minY,min(origin.y,v.maxY-region.height)))
        updateFrame()
    }

    func updateShades() {
        guard overlaysVisible && !locked && !region.isEmpty else {
            shades.forEach { $0.orderOut(nil) }; return
        }
        if shades.isEmpty {
            for _ in 0..<4 {
                let shade = panel(.zero,passthrough:true)
                shade.coversFullDisplay = true
                shade.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue-1)
                shade.backgroundColor = NSColor.black.withAlphaComponent(0.22)
                shades.append(shade)
            }
        }
        let bounds = screen.frame
        let selected = region.intersection(bounds)
        guard !selected.isNull else { shades.forEach { $0.orderOut(nil) }; return }
        let rectangles = [
            CGRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:selected.minY-bounds.minY),
            CGRect(x:bounds.minX,y:selected.maxY,width:bounds.width,height:bounds.maxY-selected.maxY),
            CGRect(x:bounds.minX,y:selected.minY,width:selected.minX-bounds.minX,height:selected.height),
            CGRect(x:selected.maxX,y:selected.minY,width:bounds.maxX-selected.maxX,height:selected.height)
        ]
        for (shade,rect) in zip(shades,rectangles) {
            shade.setFrame(rect,display:true)
            if rect.isEmpty { shade.orderOut(nil) }
            else if let frame = frame { shade.order(.below,relativeTo:frame.windowNumber) }
        }
    }

    func updateFrame() {
        frame?.setFrame(region.insetBy(dx: -2, dy: -2), display: true)
        layoutResizeHandles(corners,around:region,visible:overlaysVisible)
        layoutPreview()
        updateShades()
        persistLayout()
    }

    func showOverlays(showRegion:Bool = true) {
        if showRegion { overlaysVisible = true }
        if frame == nil {
            frame = panel(.zero, passthrough: locked)
            let interior = RegionDragView(frame:.zero)
            interior.allowed = { [weak self] in !(self?.locked ?? true) }
            interior.moved = { [weak self] point in self?.moveRegion(CGPoint(x:point.x+2,y:point.y+2)) }
            frame?.contentView = interior
            frame?.contentView?.wantsLayer = true
            frame?.contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            frame?.contentView?.layer?.borderWidth = 1
            for edge in ["left","right","top","bottom","top-left","top-right","bottom-left","bottom-right"] {
                let p = panel(.zero,passthrough:false)
                let control = PromptResizeView(frame:.zero); control.edge = edge
                control.allowed = { [weak self] in !(self?.locked ?? true) }
                control.body = { [weak self] in self?.region ?? .zero }
                control.resized = { [weak self] initial,edge,delta in
                    guard let self = self, !self.locked else { return }
                    let result = resizedRegion(initial,edge:edge,delta:delta,bounds:self.screen.visibleFrame,width:self.width,height:self.height)
                    self.region = result.rect; self.width = result.width; self.height = result.height
                    self.persistConfiguration(); self.updateFrame()
                }
                p.contentView = control; corners.append(p)
            }
            if region.isEmpty { placeRegion() }
            let body = storedPromptFrame ?? clampedOverlay(CGRect(x: region.midX - 320, y: region.maxY - 240, width: 640, height: 200),bounds:screen.visibleFrame.insetBy(dx:8,dy:120))
            prompter = panel(body, passthrough: false)
            prompter?.acceptsKeyboard = true
            let sc = PromptScrollView(frame: CGRect(origin: .zero, size: body.size))
            sc.contentView = PromptClipView(frame:sc.bounds)
            sc.drawsBackground = false; sc.contentView.drawsBackground = false
            sc.contentView.backgroundColor = .clear
            sc.wantsLayer = true; sc.layer?.cornerRadius = 14
            sc.layer?.backgroundColor = promptBackgroundColor.cgColor
            sc.layer?.borderWidth = 0.5; sc.layer?.borderColor = NSColor.gray.withAlphaComponent(0.25).cgColor
            let text = PromptTextView(frame:CGRect(origin:.zero,size:body.size))
            text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
            text.delegate = self
            text.isRichText = false; text.allowsUndo = true
            text.textColor = .white; text.font = .systemFont(ofSize: fontSize)
            text.textContainerInset = NSSize(width: 20, height: 20)
            text.textContainer?.widthTracksTextView = true
            text.isVerticallyResizable = true
            text.string = preferences.string(forKey: "script") ?? ""
            sc.documentView = text; prompter?.contentView = sc
            promptText = text; scroll = sc
            text.interactionBegan = { [weak self] in self?.beginPromptInteraction() }
            text.moved = { [weak self] point in self?.movePrompter(point) }
            for edge in ["left","right","top","bottom","top-left","top-right","bottom-left","bottom-right"] {
                let p = panel(.zero,passthrough:false)
                let view = PromptResizeView(frame:.zero); view.edge = edge
                view.body = { [weak self] in self?.prompter?.frame ?? .zero }
                view.resized = { [weak self] initial,edge,delta in
                    guard let self = self else { return }
                    let visible = self.prompter?.screen?.visibleFrame ?? self.screen.visibleFrame
                    let prospective = resizedPrompt(initial,edge:edge,delta:delta,bounds:visible)
                    let toolbar = self.promptToolbarHeight(prospective.width)
                    let bounds = CGRect(x:visible.minX+8,y:visible.minY+toolbar,width:visible.width-16,height:visible.height-toolbar-8)
                    self.resizePrompter(resizedPrompt(initial,edge:edge,delta:delta,bounds:bounds))
                }
                p.contentView = view; promptResizers.append(p)
                // Child windows stay above the text body when AppKit brings that
                // body forward for typing or a mouse gesture. Keep the complete
                // 12-point corner hit target, including the half over the body.
                prompter?.addChildWindow(p,ordered:.above)
            }
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
        updateFrame(); updateInteraction()
        for p in [frame] { if overlaysVisible { p?.orderFrontRegardless() } else { p?.orderOut(nil) } }
        corners.forEach { if overlaysVisible { $0.orderFrontRegardless() } else { $0.orderOut(nil) } }
        for p in [prompter] { if promptVisible { p?.orderFrontRegardless() } else { p?.orderOut(nil) } }
        layoutPromptHandles()
        showCameraPreview()
    }

    func showCameraPreview() {
        if camera, let engine = engine, engine.cameraEnabled, engine.cameraID == cameraID {
            if preview == nil {
                if previewRect.isEmpty {
                    let v = screen.visibleFrame
                    previewRect = CGRect(x:v.maxX-248,y:v.minY+24,width:224,height:126)
                }
                preview = panel(previewRect,passthrough:false)
                let handle = PreviewDragView(frame: CGRect(x:0,y:0,width:224,height:126))
                handle.moved = { [weak self] point in
                    guard let self = self else { return }
                    if let linked = linkedFillDrag(layout:self.previewLayout,overlaysVisible:self.overlaysVisible,previewOrigin:point) {
                        guard !self.locked else { return }
                        self.moveRegion(linked)
                        return
                    }
                    self.previewPosition = "manual"; self.previewLayout = "small"
                    let size = self.preview?.frame.size ?? self.previewRect.size
                    self.previewRect = clampedOverlay(CGRect(origin:point,size:size),bounds:self.bestScreen(for:CGRect(origin:point,size:size)).visibleFrame.insetBy(dx:8,dy:8),minimum:CGSize(width:120,height:80))
                    self.preferences.set("manual",forKey:"previewPosition"); self.preferences.set("small",forKey:"previewLayout")
                    self.layoutPreview()
                }
                preview?.contentView = handle
                handle.wantsLayer = true
                handle.layer?.backgroundColor = NSColor.clear.cgColor
                handle.layer?.masksToBounds = false
                let gear = NSButton(image: NSImage(systemSymbolName:"gearshape",accessibilityDescription:"Camera settings")!, target:self, action:#selector(cameraSettings(_:)))
                gear.frame = CGRect(x:180,y:84,width:36,height:36)
                gear.setAccessibilityLabel(language == "zh-CN" ? "摄像头设置" : "Camera settings")
                gear.autoresizingMask = [.minXMargin, .minYMargin]
                gear.bezelStyle = .regularSquare
                handle.addSubview(gear)
                for edge in ["left","right","top","bottom","top-left","top-right","bottom-left","bottom-right"] {
                    let p = panel(.zero,passthrough:false)
                    let resize = PromptResizeView(frame:.zero); resize.edge = edge
                    resize.body = { [weak self] in self?.preview?.frame ?? .zero }
                    resize.resized = { [weak self] initial,edge,delta in
                        guard let self = self else { return }
                        self.previewRect = resizedOverlay(initial,edge:edge,delta:delta,bounds:self.bestScreen(for:initial).visibleFrame.insetBy(dx:8,dy:8),minimum:CGSize(width:120,height:80))
                        self.previewLayout = "small"; self.previewPosition = "manual"
                        self.preferences.set("small",forKey:"previewLayout"); self.preferences.set("manual",forKey:"previewPosition")
                        self.layoutPreview()
                    }
                    p.contentView = resize; previewResizers.append(p)
                }
            }
            previewLayer?.removeFromSuperlayer()
            let layer = AVCaptureVideoPreviewLayer(session: engine.session)
            previewLayer = layer
            preview?.contentView?.layer?.insertSublayer(layer, at:0)
            layoutPreview()
            preview?.orderFrontRegardless()
            layoutResizeHandles(previewResizers,around:preview?.frame ?? previewRect,visible:previewLayout == "small")
        } else { preview?.orderOut(nil); previewResizers.forEach { $0.orderOut(nil) } }
    }

    func beginPromptInteraction() {
        playing = false
        updatePromptInteraction()
    }

    func movePrompter(_ origin:CGPoint) {
        guard let body = prompter?.frame else { return }
        let v = NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) })?.visibleFrame ?? prompter?.screen?.visibleFrame ?? screen.visibleFrame
        let x = max(v.minX+8,min(origin.x,v.maxX-body.width-8))
        let y = max(v.minY+promptToolbarHeight(body.width),min(origin.y,v.maxY-body.height-8))
        prompter?.setFrameOrigin(CGPoint(x:x,y:y)); layoutPromptHandles()
    }

    // Match the global UI palette in index.css, with opacity on the fill only.
    var promptBackgroundColor: NSColor {
        theme == "light" ? NSColor(srgbRed:1,green:1,blue:1,alpha:promptOpacity) : NSColor(srgbRed:32/255,green:34/255,blue:38/255,alpha:promptOpacity)
    }
    var promptForegroundColor: NSColor {
        theme == "light" ? NSColor(srgbRed:24/255,green:24/255,blue:27/255,alpha:1) : NSColor(srgbRed:250/255,green:250/255,blue:250/255,alpha:1)
    }

    func updatePromptInteraction() {
        promptText?.setAccessibilityLabel(language == "en" ? "Script body" : "口播稿正文")
        promptText?.isEditable = true
        promptText?.isSelectable = true
        prompter?.ignoresMouseEvents = false
        let light = theme == "light"
        prompter?.appearance = NSAppearance(named:light ? .aqua : .darkAqua)
        scroll?.drawsBackground = false
        scroll?.contentView.drawsBackground = false
        scroll?.contentView.backgroundColor = .clear
        scroll?.layer?.backgroundColor = promptBackgroundColor.cgColor
        promptText?.textColor = promptForegroundColor
        promptText?.insertionPointColor = promptForegroundColor
    }

    func textDidChange(_ notification:Notification) {
        guard let text = notification.object as? NSTextView, text === promptText else { return }
        preferences.set(text.string,forKey:"script")
    }

    func layoutResizeHandles(_ panels:[CapturePanel], around body:CGRect, visible:Bool) {
        for p in panels {
            guard let view = p.contentView as? PromptResizeView else { continue }
            let corner = view.edge.contains("-")
            let x = view.edge.contains("left") ? body.minX : view.edge.contains("right") ? body.maxX : body.midX
            let y = view.edge.contains("bottom") ? body.minY : view.edge.contains("top") ? body.maxY : body.midY
            let size = corner ? CGSize(width:12,height:12) : (["left","right"].contains(view.edge) ? CGSize(width:8,height:max(20,body.height-24)) : CGSize(width:max(20,body.width-24),height:8))
            p.setFrame(CGRect(x:x-size.width/2,y:y-size.height/2,width:size.width,height:size.height),display:true)
            if visible { p.orderFrontRegardless() } else { p.orderOut(nil) }
        }
    }

    func layoutPromptHandles() {
        guard let body = prompter?.frame else { return }
        layoutResizeHandles(promptResizers,around:body,visible:promptVisible)
        persistLayout()
    }

    func promptToolbarHeight(_ width:CGFloat) -> CGFloat {
        let base:CGFloat = width <= 480 ? 104 : width <= 600 ? 72 : 40
        return base + (language == "en" ? 32 : 0)
    }

    func resizePrompter(_ requested:CGRect) {
        let v = prompter?.screen?.visibleFrame ?? screen.visibleFrame
        let width = min(max(320,requested.width),v.width-16)
        let toolbar = promptToolbarHeight(width)
        let height = min(max(120,requested.height),v.height-toolbar-8)
        let rect = CGRect(x:max(v.minX+8,min(requested.minX,v.maxX-width-8)),y:max(v.minY+toolbar,min(requested.minY,v.maxY-height-8)),width:width,height:height)
        let offset = scroll?.contentView.bounds.origin ?? .zero
        prompter?.setFrame(rect,display:true)
        scroll?.frame = CGRect(origin:.zero,size:rect.size)
        if let text = promptText, let sc = scroll {
            text.setFrameSize(CGSize(width:rect.width,height:max(rect.height,text.frame.height)))
            if let container = text.textContainer, let layout = text.layoutManager {
                layout.ensureLayout(for:container)
                text.setFrameSize(CGSize(width:rect.width,height:max(rect.height,layout.usedRect(for:container).height+text.textContainerInset.height*2)))
            }
            sc.contentView.scroll(to:CGPoint(x:0,y:min(offset.y,max(0,text.frame.height-sc.contentView.bounds.height))))
            sc.reflectScrolledClipView(sc.contentView)
        }
        layoutPromptHandles()
    }

    @objc func cameraSettings(_ sender:NSButton) {
        let anchor = sender.window.map { uiRect($0.convertToScreen(sender.convert(sender.bounds,to:nil))) }
        Task { @MainActor in
            do { try await deviceMenu(kind:"preview",anchor:anchor) }
            catch { self.error = error.localizedDescription }
        }
    }

    var menuSelection: [String:Any]?
    @objc func selectMenuItem(_ sender: NSMenuItem) { menuSelection = sender.representedObject as? [String:Any] }

    func makeDeviceMenu(kind:String) throws -> NSMenu {
        guard ["camera","audio","preview"].contains(kind) else { throw ProbeError.message("invalid_device_kind") }
        let isCamera = kind != "audio", zh = language == "zh-CN"
        let enabled = isCamera ? camera : microphone
        let id = isCamera ? cameraID : microphoneID
        let media: AVMediaType = isCamera ? .video : .audio
        let effectiveID = id.isEmpty ? AVCaptureDevice.default(for:media)?.uniqueID ?? "" : id
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title:String, checked:Bool, data:[String:Any], device:Bool = false, into:NSMenu) {
            let entry = NSMenuItem(title:title,action:#selector(selectMenuItem(_:)),keyEquivalent:"")
            entry.target = self; entry.representedObject = data; entry.state = checked ? .on : .off
            entry.isEnabled = !device || !locked; into.addItem(entry)
        }
        let key = isCamera ? "camera" : "microphone", idKey = isCamera ? "cameraID" : "microphoneID"
        if kind == "preview" {
          if overlaysVisible {
            for (value,title) in [("small",zh ? "小窗" : "Small"),("fill",zh ? "填满" : "Fill")] {
                item(title,checked:previewLayout == value,data:["action":"preview","layout":value],into:menu)
            }
            menu.addItem(.separator())
            for (value,title) in [("top-left",zh ? "左上" : "Top left"),("top-right",zh ? "右上" : "Top right"),("bottom-left",zh ? "左下" : "Bottom left"),("bottom-right",zh ? "右下" : "Bottom right")] {
                item(title,checked:previewPosition == value,data:["action":"preview","position":value],into:menu)
                menu.items.last?.isEnabled = camera && previewLayout != "fill"
            }
            menu.addItem(.separator())
            if previewLayout == "small" {
                for (value,title) in [("square",zh ? "方形" : "Square"),("circle",zh ? "圆形" : "Circle")] {
                    item(title,checked:previewShape == value,data:["action":"preview","shape":value],into:menu)
                }
                menu.addItem(.separator())
            }
          }
            item(zh ? "左右翻转" : "Flip horizontally",checked:mirror,data:["action":"preview","mirror":!mirror],into:menu)
            for entry in menu.items where !entry.isSeparatorItem { entry.isEnabled = entry.isEnabled && camera }
            return menu
        }
        item(isCamera ? (zh ? "不录制摄像头" : "No camera") : (zh ? "静音录制" : "No microphone"),checked:!enabled,data:["action":"configure",key:false],device:true,into:menu)
        for device in captureDevices(media) {
            item(device.localizedName,checked:enabled && effectiveID == device.uniqueID,data:["action":"configure",key:true,idKey:device.uniqueID],device:true,into:menu)
        }
        return menu
    }

    func deviceMenu(kind:String, anchor:[Double]?) async throws {
        let menu = try makeDeviceMenu(kind:kind)
        let isCamera = kind != "audio"
        let rect: CGRect
        if let a = anchor, a.count == 4, a.allSatisfy({ $0.isFinite }) {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            rect = CGRect(x:a[0],y:top-a[1]-a[3],width:a[2],height:a[3])
        } else { rect = (isCamera ? preview?.frame : nil) ?? CGRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:0,height:0) }
        menuSelection = nil
        menu.popUp(positioning:nil,at:CGPoint(x:rect.minX,y:rect.minY),in:nil)
        if let selection = menuSelection {
            menuSelection = nil
            _ = try await request(selection)
        }
    }

    func layoutPreview() {
        guard let preview = preview else { return }
        let rect = previewLayout == "fill" && overlaysVisible && !region.isEmpty ? region : previewRect
        guard !rect.isEmpty else { return }
        let size = rect.size
        preview.setFrame(rect,display:true)
        if let gear = preview.contentView?.subviews.first as? NSButton { gear.frame = CGRect(x:size.width-44,y:size.height-42,width:36,height:36) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer?.frame = CGRect(origin:.zero,size:size)
        let circular = previewLayout == "small" && previewShape == "circle"
        (preview.contentView as? PreviewDragView)?.circular = circular
        let mask = CAShapeLayer(); mask.frame = CGRect(origin:.zero,size:size)
        mask.path = previewOutline(mask.bounds,circular:circular)
        previewLayer?.mask = mask
        previewLayer?.videoGravity = .resizeAspectFill
        if let connection = previewLayer?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }
        CATransaction.commit()
        layoutResizeHandles(previewResizers,around:rect,visible:camera && preview.isVisible && previewLayout == "small")
        persistLayout()
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

    func deviceReady(_ kind:AVMediaType) -> Bool {
        guard let engine = engine, engine.session.isRunning else { return false }
        let enabled = kind == .video ? camera && engine.cameraEnabled && engine.cameraID == cameraID : microphone && engine.microphoneEnabled && engine.microphoneID == microphoneID
        return enabled && engine.session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.contains { $0.device.hasMediaType(kind) && $0.device.isConnected }
    }

    func observeMonitoring(_ e:Engine) {
        monitorObservers.forEach { NotificationCenter.default.removeObserver($0) }; monitorObservers.removeAll()
        monitorObservers.append(NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:e.session,queue:nil) { [weak self,weak e] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "device_unavailable"
            Task { @MainActor in
                guard let self = self, self.engine === e, !self.locked else { return }
                self.monitorError = message
            }
        })
        monitorObservers.append(NotificationCenter.default.addObserver(forName:AVCaptureDevice.wasDisconnectedNotification,object:nil,queue:nil) { [weak self,weak e] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            Task { @MainActor in
                guard let self = self, let e = e, self.engine === e, !self.locked else { return }
                if e.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).contains(where:{ $0.device.uniqueID == device.uniqueID }) {
                    self.monitorError = "device_missing"
                    if device.hasMediaType(.video) { self.preview?.orderOut(nil); self.previewResizers.forEach { $0.orderOut(nil) } }
                }
            }
        })
    }

    func snapshot() -> [String: Any] {
        refreshDevices()
        let details = engine?.metadata ?? [:]
        let body = prompter?.frame ?? .zero
        let toolbarHeight = promptToolbarHeight(body.width)
        let promptBar = CGRect(x:body.minX,y:body.minY-toolbarHeight,width:body.width,height:toolbarHeight)
        let toolbarFrames = [screen.visibleFrame] + NSScreen.screens.filter { $0 != screen }.map(\.visibleFrame)
        let sizeBar = regionToolbarPlacement(region:region,size:CGSize(width:520,height:88),visibleFrames:toolbarFrames)
        return ["phase": phase, "error": error, "remaining": remaining,
                "monitoringActive":engine?.session.isRunning ?? false,"cameraReady":deviceReady(.video),"microphoneReady":deviceReady(.audio),"monitorError":monitorError,
                "elapsed": engine.map { phase == "recording" || phase == "paused" ? $0.elapsed : 0 } ?? 0,
                "width": width, "height": height, "camera": camera, "microphone": microphone,
                "defaultCameraID":AVCaptureDevice.default(for:.video)?.uniqueID ?? "","defaultMicrophoneID":AVCaptureDevice.default(for:.audio)?.uniqueID ?? "","regionUI":uiRect(region),"catalog":deviceCatalog,"cameraID":cameraID,"microphoneID":microphoneID,"displayID":String(displayID),
                "mirror":mirror,"previewShape":previewShape,"previewLayout":previewLayout,"previewPosition":previewPosition,"promptStarted":promptStarted,"promptVisible":promptVisible,"scriptText":preferences.string(forKey:"script") ?? "",
                "overlaysVisible":overlaysVisible,"promptToolbar":uiRect(promptBar),"regionToolbar":uiRect(sizeBar.frame),
                "cameraAnchor":uiRect(preview?.frame ?? (previewRect.isEmpty ? region:previewRect)),"visibleFrame":uiRect(screen.visibleFrame),"regionToolbarVisibleFrame":uiRect(sizeBar.visibleFrame),"promptVisibleFrame":uiRect(prompter?.screen?.visibleFrame ?? screen.visibleFrame),
                "playing": playing, "fontSize": fontSize, "promptOpacity":promptOpacity, "promptSpeed": speed, "directory": artifacts.path, "result": result,
                "level": microphone ? (engine?.queue.sync { engine?.latestAudioLevel ?? 0 } ?? 0) : 0,
                "devices": ["camera": details["cameraDevice"] ?? "", "microphone": details["microphone"] ?? ""],
                "region": [region.origin.x, region.origin.y, region.width, region.height]]
    }

    // Monitoring never starts ScreenCaptureKit or allocates recording files.
    // Restoration/Area use existing authorization only; explicit device choices may ask.
    func prepareMonitoring(requestCamera:Bool = false,requestMicrophone:Bool = false) async throws {
        guard !locked else { return }
        let previousPhase = phase
        phase = "preparing"
        defer { phase = previousPhase }
        do {
            if camera && requestCamera && cameraAuthorization() != .authorized {
                guard await AVCaptureDevice.requestAccess(for:.video) else { throw ProbeError.message("camera_permission") }
            }
            if microphone && requestMicrophone && microphoneAuthorization() != .authorized {
                guard await AVCaptureDevice.requestAccess(for:.audio) else { throw ProbeError.message("microphone_permission") }
            }
            let plan = monitoringDevices(camera:camera,microphone:microphone,cameraAuthorized:cameraAuthorization() == .authorized,microphoneAuthorized:microphoneAuthorization() == .authorized)
            monitorError = camera && !plan[0] ? "camera_permission" : microphone && !plan[1] ? "microphone_permission" : ""
            error = monitorError
            if let current = engine, current.cameraEnabled == plan[0], current.microphoneEnabled == plan[1], current.cameraID == cameraID, current.microphoneID == microphoneID, current.session.isRunning {
                showCameraPreview(); return
            }
            if let old = engine {
                await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in old.setupQueue.async { old.session.stopRunning(); c.resume() } }
                engine = nil
            }
            guard plan[0] || plan[1] else { showCameraPreview(); return }
            let e = Engine(); e.cameraEnabled = plan[0]; e.microphoneEnabled = plan[1]; e.cameraID = cameraID; e.microphoneID = microphoneID
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                e.setupQueue.async {
                    do { try e.configureDevices(); e.session.startRunning(); c.resume() }
                    catch { c.resume(throwing:error) }
                }
            }
            engine = e
            observeMonitoring(e)
            e.onFailure = { [weak self] message in Task { @MainActor in self?.monitorError = message } }
            showCameraPreview()
        } catch {
            monitorError = error.localizedDescription
            self.error = error.localizedDescription
            showCameraPreview()
            throw error
        }
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
            monitorError = ""; observeMonitoring(e)
            e.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.error = message
                    if self.phase == "recording" || self.phase == "paused" || self.phase == "starting" { await self.stop() }
                    else { self.monitorError = message }
                }
            }
            showOverlays(); phase = "ready"
        } catch { phase = "idle"; self.error = error.localizedDescription; throw error }
    }

    func start() async throws {
        guard !locked else { throw ProbeError.message("session_busy") }
        if phase != "ready" || engine == nil { try await prepare() }
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
        guard ["starting", "recording", "paused"].contains(phase), let e = engine else { return }
        phase = "saving"; playing = false
        _ = await e.stop()
        result = e.metadata
        savedDirectory = e.directory
        let statuses = (result["saveResults"] as? [String: String] ?? [:]).values.filter { $0 != "not-requested" }
        let saved = statuses.filter { $0 == "saved" }.count
        phase = !statuses.isEmpty && saved == statuses.count ? "saved" : saved > 0 ? "partial" : "failed"
        startedAt = nil
        // Engine.stop finalizes files and stops ScreenCaptureKit, while its AV
        // session deliberately keeps running for the preview and live audio meter.
        observeMonitoring(e)
        monitorError = (!camera || deviceReady(.video)) && (!microphone || deviceReady(.audio)) ? "" : (e.fatalError ?? "device_unavailable")
    }

    func request(_ data: [String: Any]) async throws -> [String: Any] {
        switch data["action"] as? String {
        case "status": break
        case "restore-session":
            if !restoredSession {
                restoredSession = true
                persistConfiguration()
                if overlaysVisible || promptVisible { showOverlays(showRegion:false) }
                do { try await prepareMonitoring() } catch { monitorError = error.localizedDescription }
            }
        case "interface":
            language = data["language"] as? String ?? language
            if let resolved = data["theme"] as? String, ["light","dark"].contains(resolved) { theme = resolved }
            updatePromptInteraction()
            if let gear = preview?.contentView?.subviews.first as? NSButton { gear.setAccessibilityLabel(language == "zh-CN" ? "摄像头设置" : "Camera settings") }
        case "show-prompt":
            promptVisible = true
            showOverlays(showRegion:false)
            updatePromptInteraction()
            if !playing { prompter?.makeKeyAndOrderFront(nil); prompter?.makeFirstResponder(promptText) }
        case "focus-prompt":
            if promptVisible && !playing {
                prompter?.makeKeyAndOrderFront(nil)
                prompter?.makeFirstResponder(promptText)
            }
        case "hide-prompt":
            promptVisible = false; playing = false
            prompter?.orderOut(nil)
            promptResizers.forEach { $0.orderOut(nil) }
        case "area":
            guard !locked else { throw ProbeError.message("session_busy") }
            showOverlays()
            // Selection remains visible and usable when an authorized camera is absent.
            do { try await prepareMonitoring() }
            catch { self.error = error.localizedDescription }
        case "device-menu":
            try await deviceMenu(kind:data["kind"] as? String ?? "",anchor:data["anchor"] as? [Double])
        case "move-overlay":
            let dx = data["dx"] as? Double ?? 0, dy = data["dy"] as? Double ?? 0
            guard dx.isFinite && dy.isFinite else { throw ProbeError.message("invalid_region") }
            if data["kind"] as? String == "region" {
                guard !locked else { throw ProbeError.message("session_busy") }
                moveRegion(CGPoint(x:region.minX+dx,y:region.minY-dy))
            } else if data["kind"] as? String == "prompter", let body = prompter?.frame {
                movePrompter(CGPoint(x:body.minX+dx,y:body.minY-dy))
            }
        case "region":
            guard !locked else { throw ProbeError.message("session_busy") }
            let old = uiRect(region), top = NSScreen.screens.first?.frame.maxY ?? 0
            let x = data["x"] as? Double ?? old[0], y = data["y"] as? Double ?? old[1]
            let w = data["width"] as? Double ?? region.width, h = data["height"] as? Double ?? region.height
            let next = CGRect(x:x,y:top-y-h,width:w,height:h)
            guard [x,y,w,h].allSatisfy({ $0.isFinite }), w >= 120, h > 0,
                  abs(w/h-Double(width)/Double(height)) < 0.001,
                  screen.visibleFrame.contains(next) else { throw ProbeError.message("invalid_region") }
            region = next; updateFrame()
        case "prepare": try await prepare()
        case "start": try await start()
        case "pause":
            guard phase == "recording", let engine = engine else { throw ProbeError.message("not_recording") }
            engine.setPaused(true); phase = "paused"
        case "resume":
            guard phase == "paused", let engine = engine else { throw ProbeError.message("not_paused") }
            engine.setPaused(false); phase = "recording"
        case "stop": await stop()
        case "cancel": if phase == "countdown" { generation += 1; phase = "ready"; remaining = 0 }
        case "configure":
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
            let nextCameraEnabled = data["camera"] as? Bool ?? camera
            let nextMicrophoneEnabled = data["microphone"] as? Bool ?? microphone
            let devicesChanged = nextCamera != cameraID || nextMicrophone != microphoneID || nextCameraEnabled != camera || nextMicrophoneEnabled != microphone
            let relocate = w != width || h != height || nextDisplay != displayID
            width = w; height = h
            cameraID = nextCamera; microphoneID = nextMicrophone; displayID = nextDisplay
            camera = nextCameraEnabled; microphone = nextMicrophoneEnabled
            persistConfiguration()
            if devicesChanged { phase = "idle" }
            if relocate { placeRegion() }
            let askCamera = camera && (data["camera"] as? Bool == true || data["cameraID"] != nil)
            let askMicrophone = microphone && (data["microphone"] as? Bool == true || data["microphoneID"] != nil)
            if devicesChanged || askCamera || askMicrophone || (engine == nil && (camera || microphone)) {
                try await prepareMonitoring(requestCamera:askCamera,requestMicrophone:askMicrophone)
            }
        case "preview":
            let layout = data["layout"] as? String ?? previewLayout
            let position = data["position"] as? String ?? previewPosition
            let shape = data["shape"] as? String ?? previewShape
            guard ["square","circle"].contains(shape) else { throw ProbeError.message("invalid_preview") }
            guard ["small","fill"].contains(layout), ["top-left","top-right","bottom-left","bottom-right","manual"].contains(position) else { throw ProbeError.message("invalid_preview") }
            mirror = data["mirror"] as? Bool ?? mirror
            previewLayout = layout; previewPosition = position; previewShape = shape
            preferences.set(shape,forKey:"previewShape")
            if data["shape"] != nil {
                let side = max(120,min(previewRect.width,previewRect.height))
                previewRect = clampedOverlay(CGRect(x:previewRect.minX,y:previewRect.minY,width:side,height:side),bounds:bestScreen(for:previewRect).visibleFrame.insetBy(dx:12,dy:12))
            }
            preferences.set(mirror,forKey:"previewMirror"); preferences.set(layout,forKey:"previewLayout"); preferences.set(position,forKey:"previewPosition")
            if position != "manual" {
                if previewRect.isEmpty { previewRect = CGRect(x:screen.visibleFrame.minX+12,y:screen.visibleFrame.minY+12,width:224,height:126) }
                let bounds = bestScreen(for:previewRect).visibleFrame.insetBy(dx:12,dy:12)
                previewRect.origin = CGPoint(x:position.hasSuffix("left") ? bounds.minX:bounds.maxX-previewRect.width,y:position.hasPrefix("top") ? bounds.maxY-previewRect.height:bounds.minY)
            }
            layoutPreview()
        case "script":
            let text = data["text"] as? String ?? ""
            preferences.set(text, forKey: "script")
            promptText?.string = text
        case "prompt":
            if data["opacity"] != nil {
                guard let opacity = data["opacity"] as? Double, opacity.isFinite, (0...1).contains(opacity) else { throw ProbeError.message("invalid_prompt_opacity") }
                promptOpacity = opacity; preferences.set(opacity,forKey:"promptOpacity")
            }
            if let play = data["playing"] as? Bool { playing = play; if play { promptStarted = true } }
            if data["reset"] as? Bool == true { playing = false; promptStarted = false; scroll?.contentView.scroll(to: .zero) }
            if let size = data["fontSize"] as? Double, size >= 24, size <= 48 {
                fontSize = size; promptText?.font = .systemFont(ofSize: size)
                preferences.set(size, forKey: "promptFont")
            }
            if let rate = data["speed"] as? Double, rate >= 2, rate <= 100 {
                speed = rate; preferences.set(rate, forKey: "promptSpeed")
            }
            updatePromptInteraction()
        case "open-folder": NSWorkspace.shared.open(data["current"] as? Bool == true ? artifacts : (savedDirectory ?? artifacts))
        case "hide":
            guard !locked else { throw ProbeError.message("session_busy") }
            overlaysVisible = false
            shades.forEach { $0.orderOut(nil) }
            for p in [frame] { p?.orderOut(nil) }
            layoutPreview()
            corners.forEach { $0.orderOut(nil) }
        default: throw ProbeError.message("unknown_action")
        }
        persistLayout()
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
