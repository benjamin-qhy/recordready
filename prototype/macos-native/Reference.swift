// Separate process so the recorder's application filter does not exclude this chart.
import AppKit
import CoreMedia

final class Chart: NSView {
    var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let t = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.16, alpha: 1).setFill(); bounds.fill()
        let colors: [NSColor] = [.systemRed,.systemOrange,.systemYellow,.systemGreen,.systemCyan,.systemBlue,.systemPurple,.white]
        for (i,c) in colors.enumerated() { c.setFill(); NSRect(x:CGFloat(i)*bounds.width/8,y:0,width:bounds.width/8,height:70).fill() }
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let grid = NSBezierPath()
        for x in stride(from: 0.0, to: bounds.width, by: 60) { grid.move(to:NSPoint(x:x,y:0));grid.line(to:NSPoint(x:x,y:bounds.height)) }
        for y in stride(from: 0.0, to: bounds.height, by: 60) { grid.move(to:NSPoint(x:0,y:y));grid.line(to:NSPoint(x:bounds.width,y:y)) }
        grid.stroke()
        let text: [NSAttributedString.Key:Any] = [.foregroundColor:NSColor.white,.font:NSFont.monospacedSystemFont(ofSize:28,weight:.bold)]
        ("RECORDREADY / CAPTURE REFERENCE" as NSString).draw(at:NSPoint(x:25,y:bounds.height-65),withAttributes:text)
        (String(format:"HOST CLOCK %.3f s",t) as NSString).draw(at:NSPoint(x:25,y:bounds.height/2),withAttributes:text)
        ("No pink frame / prompt / camera / controls in output" as NSString).draw(at:NSPoint(x:25,y:bounds.height/2-50),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:18)])
        let phase = t.truncatingRemainder(dividingBy: 5)/5
        NSColor.systemGreen.setFill(); NSRect(x:phase*(bounds.width-80),y:100,width:80,height:40).fill()
        NSColor.white.setStroke();let border=NSBezierPath(rect:bounds.insetBy(dx:2,dy:2));border.lineWidth=4;border.stroke()
        for (s,p) in [("TL",NSPoint(x:5,y:bounds.height-25)),("TR",NSPoint(x:bounds.width-40,y:bounds.height-25)),("BL",NSPoint(x:5,y:5)),("BR",NSPoint(x:bounds.width-40,y:5))] {
            (s as NSString).draw(at:p,withAttributes:[.foregroundColor:NSColor.black,.backgroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:18,weight:.bold)])
        }
    }
}
final class ReferenceApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        let screen = NSScreen.screens.first!, w = min(960.0, screen.frame.width-100), h = w*9/16
        window=NSWindow(contentRect:NSRect(x:screen.frame.minX+(screen.frame.width-w)/2,y:screen.frame.minY+(screen.frame.height-h)/2,width:w,height:h),styleMask:.borderless,backing:.buffered,defer:false)
        window.title="RecordReady Capture Reference";window.contentView=Chart(frame:NSRect(x:0,y:0,width:w,height:h));window.makeKeyAndOrderFront(nil)
        let menu=NSMenu();let item=NSMenuItem();menu.addItem(item);let sub=NSMenu();item.submenu=sub
        sub.addItem(withTitle:"Quit reference",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");NSApp.mainMenu=menu
        NSApp.activate(ignoringOtherApps:true)
    }
}
let app=ReferenceApp();NSApplication.shared.delegate=app;NSApplication.shared.run()
