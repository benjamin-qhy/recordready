// THROWAWAY: separate-process pointer receiver. No capture or global event monitoring.
import AppKit
final class Surface: NSView {
    var hit: ((NSEvent)->Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { hit?(event) }
    override func draw(_ rect: NSRect) {
        NSColor.systemIndigo.setFill(); bounds.fill()
        ("独立应用接收区：在提词正文覆盖位置点击" as NSString).draw(at:NSPoint(x:30,y:570),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:25)])
    }
}
final class Target: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var rows: [[String:Any]]=[]
    let label=NSTextField(wrappingLabelWithString:"点击计数：0")
    func applicationDidFinishLaunching(_ n:Notification) {
        NSApp.setActivationPolicy(.regular)
        window=NSWindow(contentRect:NSRect(x:220,y:180,width:1000,height:640),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="RecordReady · 独立应用点击接收器"
        let view=Surface(frame:NSRect(x:0,y:0,width:1000,height:640));window.contentView=view
        label.frame=NSRect(x:30,y:60,width:930,height:110);label.textColor = .white;view.addSubview(label)
        view.hit={ [weak self] event in
            guard let self=self else{return}
            let global=self.window.convertPoint(toScreen:event.locationInWindow)
            self.rows.append(["count":self.rows.count+1,"time":Date().timeIntervalSince1970,"pid":ProcessInfo.processInfo.processIdentifier,"eventType":event.type.rawValue,"locationInScreen":[global.x,global.y]])
            self.label.stringValue="点击计数：\(self.rows.count)\n屏幕坐标：\(global)\n独立进程：\(ProcessInfo.processInfo.processIdentifier)"
            let output=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("artifacts/interaction-target.json")
            if let data=try? JSONSerialization.data(withJSONObject:self.rows,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output,options:.atomic)}
        }
        let menu=NSMenu();let item=NSMenuItem();menu.addItem(item);let sub=NSMenu();item.submenu=sub;sub.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");NSApp.mainMenu=menu
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}
let target=Target();NSApplication.shared.delegate=target;NSApplication.shared.run()
