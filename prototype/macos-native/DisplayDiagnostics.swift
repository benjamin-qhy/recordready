// Read-only display geometry probe. Does not capture screen or start camera/mic.
import AppKit
import CoreGraphics
import Foundation

var displays: [[String: Any]] = []
for screen in NSScreen.screens {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { continue }
    let id = number.uint32Value
    let sample = NSRect(x: screen.frame.midX - 480, y: screen.frame.midY - 270, width: 960, height: 540)
    let backing = screen.convertRectToBacking(sample)
    displays.append([
        "builtIn": CGDisplayIsBuiltin(id) != 0,
        "appKitFramePoints": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height],
        "backingScaleFactor": screen.backingScaleFactor,
        "cgDisplayReportedSize": [CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id)],
        "modeSize": [mode.width, mode.height],
        "modePixelSize": [mode.pixelWidth, mode.pixelHeight],
        "sampleRegionPoints": [sample.width, sample.height],
        "sampleRegionBackingPixels": [backing.width, backing.height],
        "note": "Mode/backing pixels describe the active configuration, not guaranteed physical panel resolution or captured buffer size."
    ])
}
let data = try JSONSerialization.data(withJSONObject: displays, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
