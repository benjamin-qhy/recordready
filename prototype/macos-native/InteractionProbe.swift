// THROWAWAY: macOS hit testing only. No capture, permissions, or production integration.
import AppKit

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
final class HitSurface: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onHit: ((NSEvent) -> Void)?
    var label: String
    init(_ label: String, frame: NSRect) { self.label = label; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill(); bounds.fill()
        (label as NSString).draw(in: bounds.insetBy(dx: 20, dy: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { onHit?(event) }
}
final class DragSurface: NSView {
    var observed: ((String, NSEvent) -> Void)?
    var anchor: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        anchor = event.locationInWindow
        observed?("handleMouseDown", event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window = window, let anchor = anchor else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: pointer.x-anchor.x, y: pointer.y-anchor.y))
        observed?("handleMouseDragged", event)
    }
    override func mouseUp(with event: NSEvent) {
        anchor = nil
        observed?("handleMouseUp", event)
    }
}
final class Probe: NSObject, NSApplicationDelegate {
    var host: NSWindow!, body: NSWindow!, handle: NSWindow!
    var hostHits = 0, bodyHits = 0, settingsHits = 0
    let status = NSTextField(wrappingLabelWithString: "")
    let toggle = NSButton(title: "切换正文穿透", target: nil, action: nil)
    var rows: [[String: Any]] = []
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("artifacts/interaction-probe.json")
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        host = NSWindow(contentRect: NSRect(x: 220,y: 180,width: 1000,height: 640),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        host.title = "RecordReady · 鼠标穿透临时实验（不录制）"
        let surface = HitSurface("底层接收区：点击提词正文覆盖的位置，计数应增加。", frame: NSRect(x: 0,y: 0,width: 1000,height: 640))
        surface.onHit = { [weak self] e in self?.hostHits += 1; self?.record("underlyingMouseDown", e) }
        host.contentView = surface
        status.frame = NSRect(x: 30,y: 40,width: 930,height: 110); status.textColor = .white
        surface.addSubview(status)
        toggle.frame = NSRect(x: 30,y: 170,width: 200,height: 40); toggle.target = self; toggle.action = #selector(flip)
        surface.addSubview(toggle)
        let focus = NSButton(title: "选中拖动把手",target: self,action: #selector(focusHandle)); focus.frame = NSRect(x: 250,y: 170,width: 200,height: 40); surface.addSubview(focus)
        body = KeyWindow(contentRect: NSRect(x: 370,y: 450,width: 600,height: 160),styleMask: .borderless,backing: .buffered,defer: false)
        body.title = "提词正文 · 穿透实验"; body.level = .floating; body.ignoresMouseEvents = true
        body.isOpaque = false; body.alphaValue = 0.78; body.hasShadow = false
        let words = HitSurface("提词正文覆盖区\n穿透开启时，点击此处应到达底层。",frame: NSRect(x: 0,y: 0,width: 600,height: 160))
        words.onHit = { [weak self] e in self?.bodyHits += 1; self?.record("bodyMouseDown", e) }
        body.contentView = words
        handle = KeyWindow(contentRect: NSRect(x: 370,y: 610,width: 600,height: 44),styleMask: .borderless,backing: .buffered,defer: false)
        handle.title = "提词拖动把手"; handle.level = .floating; handle.backgroundColor = .systemPink
        let drag = DragSurface(frame: NSRect(x: 0,y: 0,width: 600,height: 44))
        drag.observed = { [weak self] name, event in self?.record(name, event) }
        handle.contentView = drag
        let caption = NSTextField(labelWithString: "拖动这里 · 正文应跟随")
        caption.frame = NSRect(x: 16,y: 10,width: 350,height: 25); drag.addSubview(caption)
        let settings = NSButton(title: "设置响应",target: self,action: #selector(setting)); settings.frame = NSRect(x: 460,y: 5,width: 125,height: 34); drag.addSubview(settings)
        handle.addChildWindow(body, ordered: .below)
        host.makeKeyAndOrderFront(nil); body.orderFrontRegardless(); handle.orderFrontRegardless()
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let sub = NSMenu(); item.submenu = sub
        sub.addItem(withTitle: "Quit",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q"); NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true); record("ready")
    }
    @objc func focusHandle() { handle.makeKeyAndOrderFront(nil); record("focusHandle") }
    @objc func flip() { body.ignoresMouseEvents.toggle(); record("togglePassThrough") }
    @objc func setting() { settingsHits += 1; record("settingsAction") }
    func record(_ event: String, _ mouse: NSEvent? = nil) {
        func frame(_ w: NSWindow) -> [Double] { let r=w.frame; return [r.minX,r.minY,r.width,r.height] }
        var row: [String: Any] = ["event":event,"time":Date().timeIntervalSince1970,"passThrough":body.ignoresMouseEvents,"underlyingHits":hostHits,"bodyHits":bodyHits,"settingsHits":settingsHits,"bodyFrame":frame(body),"handleFrame":frame(handle)]
        if let mouse=mouse { row["eventType"] = mouse.type.rawValue; row["eventWindowNumber"] = mouse.windowNumber; row["eventLocation"] = [mouse.locationInWindow.x,mouse.locationInWindow.y] }
        rows.append(row)
        status.stringValue = "穿透：\(body.ignoresMouseEvents ? "开启" : "关闭（负向对照）")\n底层点击：\(hostHits) · 正文拦截：\(bodyHits) · 设置响应：\(settingsHits)\n最后事件：\(event)\n把手位置：\(handle.frame.origin)；正文位置：\(body.frame.origin)"
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),withIntermediateDirectories: true)
        if let data=try? JSONSerialization.data(withJSONObject: rows,options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: output,options: .atomic) }
    }
}
let probe=Probe(); NSApplication.shared.delegate=probe; NSApplication.shared.run()
