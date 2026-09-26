import Foundation
import AppKit
import AVFoundation

// No camera, microphone or screen access. Tests the new bridge guards and writer.
@main struct NativeTests {
    @MainActor static func main() async throws {
        let suite = "recordready.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recorder = Recorder(preferences: preferences)
        var pauseClock = RecordingPauseClock()
        pauseClock.pause(at: CMTime(seconds: 2, preferredTimescale: 600))
        precondition(pauseClock.isPaused)
        pauseClock.resume(at: CMTime(seconds: 7, preferredTimescale: 600))
        precondition(!pauseClock.isPaused)
        precondition(!pauseClock.accepts(CMTime(seconds:6.9,preferredTimescale:600)), "buffered samples captured during pause must be dropped after resume")
        precondition(pauseClock.accepts(CMTime(seconds:7,preferredTimescale:600)))
        precondition(abs(pauseClock.outputTime(at:CMTime(seconds:9,preferredTimescale:600), epoch:.zero).seconds-4) < 0.0001,
                     "paused wall-clock time must be removed from recorded timestamps")
        pauseClock.pause(at:CMTime(seconds:10,preferredTimescale:600))
        precondition(abs(pauseClock.outputTime(at:CMTime(seconds:30,preferredTimescale:600),epoch:.zero).seconds-5) < 0.0001,
                     "elapsed recording time must freeze while paused")
        let pauseEngine = Engine(); pauseEngine.recording = true
        recorder.engine = pauseEngine; recorder.phase = "recording"
        _ = try await recorder.request(["action":"pause"])
        precondition(recorder.phase == "paused" && pauseEngine.pauseClock.isPaused)
        _ = try await recorder.request(["action":"resume"])
        precondition(recorder.phase == "recording" && !pauseEngine.pauseClock.isPaused)
        recorder.engine = nil; recorder.phase = "idle"
        precondition(!recorder.camera && !recorder.microphone, "first use devices must be off")
        precondition(monitoringDevices(camera:true,microphone:true,cameraAuthorized:false,microphoneAuthorized:true) == [false,true])
        precondition(monitoringDevices(camera:true,microphone:false,cameraAuthorized:true,microphoneAuthorized:true) == [true,false])
        precondition(monitoringDevices(camera:true,microphone:true,cameraAuthorized:true,microphoneAuthorized:true) == [true,true])
        let cameraMenu = try recorder.makeDeviceMenu(kind:"camera")
        precondition(cameraMenu.items.first?.title == "不录制摄像头")
        precondition(cameraMenu.items.allSatisfy { ($0.representedObject as? [String:Any])?["action"] as? String == "configure" })
        recorder.camera = true
        let standaloneMenu = try recorder.makeDeviceMenu(kind:"preview")
        precondition(standaloneMenu.items.map { $0.title } == ["左右翻转"])
        recorder.overlaysVisible = true
        let previewMenu = try recorder.makeDeviceMenu(kind:"preview")
        precondition(previewMenu.items.filter { !$0.isSeparatorItem }.map { $0.title } == ["小窗","填满","左上","右上","左下","右下","方形","圆形","左右翻转"])
        precondition(previewMenu.items.allSatisfy { $0.submenu == nil })
        recorder.previewLayout = "fill"
        let fillMenu = try recorder.makeDeviceMenu(kind:"preview")
        precondition(!fillMenu.items.contains { ["方形","圆形","不录制摄像头"].contains($0.title) })
        recorder.previewLayout = "small"
        recorder.previewRect = CGRect(x:100,y:100,width:224,height:126)
        _ = try await recorder.request(["action":"preview","shape":"circle"])
        precondition(recorder.previewRect.width == recorder.previewRect.height)
        precondition(Recorder(preferences:preferences).previewShape == "circle")
        precondition(!previewOutline(CGRect(x:0,y:0,width:100,height:100),circular:true).contains(CGPoint(x:1,y:1)))
        precondition(previewOutline(CGRect(x:0,y:0,width:100,height:100),circular:true).contains(CGPoint(x:50,y:50)))
        let previewEngine = Engine(); previewEngine.cameraEnabled = true
        recorder.engine = previewEngine
        recorder.showCameraPreview()
        precondition(recorder.previewLayer?.mask is CAShapeLayer)
        precondition(recorder.preview?.contentView?.layer?.masksToBounds == false, "shape must not clip gear")
        precondition(recorder.previewResizers.count == 8)
        let resizedCamera = resizedOverlay(recorder.previewRect,edge:"right",delta:CGPoint(x:40,y:0),bounds:recorder.screen.visibleFrame,minimum:CGSize(width:120,height:80))
        recorder.previewRect = resizedCamera; recorder.layoutPreview()
        precondition(recorder.previewRect.width != recorder.previewRect.height)
        precondition((recorder.previewLayer?.mask as? CAShapeLayer)?.path?.boundingBox.size == recorder.previewRect.size)
        precondition((recorder.preview?.contentView as? PreviewDragView)?.circular == true)
        recorder.camera = false; recorder.overlaysVisible = false
        recorder.showCameraPreview(); recorder.engine = nil
        let linked = linkedFillDrag(layout:"fill",overlaysVisible:true,previewOrigin:CGPoint(x:300,y:240))
        precondition(linked == CGPoint(x:300,y:240), "dragging a fill preview must move the capture region")
        precondition(linkedFillDrag(layout:"small",overlaysVisible:true,previewOrigin:CGPoint(x:300,y:240)) == nil)
        let geometryBounds = CGRect(x:0,y:0,width:1200,height:900)
        let geometryInitial = CGRect(x:200,y:200,width:600,height:400)
        for corner in ["top-left","top-right","bottom-left","bottom-right"] {
            let resized = resizedOverlay(geometryInitial,edge:corner,delta:CGPoint(x:85,y:110),bounds:geometryBounds,minimum:CGSize(width:120,height:80))
            precondition(abs(resized.width/resized.height-1.5) < 0.0001)
            precondition(geometryBounds.contains(resized))
        }
        let freeRegion = resizedRegion(geometryInitial,edge:"right",delta:CGPoint(x:90,y:0),bounds:geometryBounds,width:1200,height:800)
        precondition(freeRegion.height == 800 && freeRegion.width == 1380)
        precondition(abs(freeRegion.rect.width/freeRegion.rect.height-Double(freeRegion.width)/Double(freeRegion.height)) < 0.0001)
        let boundedRegion = resizedRegion(geometryInitial,edge:"top",delta:CGPoint(x:0,y:100000),bounds:geometryBounds,width:1200,height:800)
        precondition(boundedRegion.width == 1200 && boundedRegion.height % 2 == 0 && geometryBounds.contains(boundedRegion.rect))
        let toolbarSize = CGSize(width:520,height:88)
        let toolbarBounds = CGRect(x:0,y:0,width:1440,height:900)
        let aboveRegion = CGRect(x:470,y:260,width:500,height:360)
        let aboveToolbar = regionToolbarPlacement(region:aboveRegion,size:toolbarSize,visibleFrames:[toolbarBounds])
        precondition(aboveToolbar.frame.minY == aboveRegion.maxY + 12, "region toolbar must prefer the space above the selected area")
        precondition(toolbarBounds.contains(aboveToolbar.frame) && !aboveToolbar.frame.intersects(aboveRegion))
        let leftRegion = CGRect(x:700,y:690,width:500,height:180)
        let leftToolbar = regionToolbarPlacement(region:leftRegion,size:toolbarSize,visibleFrames:[toolbarBounds])
        precondition(leftToolbar.frame.maxX == leftRegion.minX - 12, "region toolbar must fall back to the left")
        precondition(!leftToolbar.frame.intersects(leftRegion))
        let rightRegion = CGRect(x:100,y:690,width:500,height:180)
        let rightToolbar = regionToolbarPlacement(region:rightRegion,size:toolbarSize,visibleFrames:[toolbarBounds])
        precondition(rightToolbar.frame.minX == rightRegion.maxX + 12, "region toolbar must fall back to the right")
        precondition(!rightToolbar.frame.intersects(rightRegion))
        let belowRegion = CGRect(x:10,y:690,width:1420,height:180)
        let belowToolbar = regionToolbarPlacement(region:belowRegion,size:toolbarSize,visibleFrames:[toolbarBounds])
        precondition(belowToolbar.frame.maxY == belowRegion.minY - 12, "region toolbar must fall back below the selected area")
        precondition(!belowToolbar.frame.intersects(belowRegion))
        var quitRequests = 0
        let delegate = QuitDelegate(original: nil) { quitRequests += 1 }
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        precondition(quitRequests == 1)
        delegate.allowed = true
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        for phase in ["preparing", "countdown", "starting", "recording", "paused", "saving"] {
            recorder.phase = phase
            do { _ = try await recorder.request(["action":"configure", "width":1920, "height":1080]); fatalError("configuration must be locked") }
            catch { precondition(error.localizedDescription == "session_busy") }
        }
        recorder.phase = "countdown"
        recorder.remaining = 2
        let cancelled = try await recorder.request(["action":"cancel"])
        precondition(cancelled["phase"] as? String == "ready")
        precondition(cancelled["remaining"] as? Int == 0)
        recorder.phase = "idle"
        for n in [0,239,241,3842] {
            do { _ = try await recorder.request(["action":"configure", "width":n, "height":1920]); fatalError("invalid size accepted") }
            catch { precondition(error.localizedDescription == "invalid_size") }
        }
        precondition(recorder.width == 1080 && recorder.height == 1920)
        do { _ = try await recorder.request(["action":"configure", "width":1920,"height":1080,"directory":"/does-not-exist/RecordReady"]); fatalError("invalid folder accepted") }
        catch { precondition(error.localizedDescription == "directory_unwritable") }
        precondition(recorder.width == 1080, "failed configuration must be atomic")
        _ = try await recorder.request(["action":"configure","width":1000,"height":800,"camera":false,"microphone":false])
        _ = try await recorder.request(["action":"prompt","fontSize":40.0,"speed":12.0])
        let restored = Recorder(preferences: preferences)
        precondition(restored.width == 1000 && restored.height == 800 && !restored.camera && !restored.microphone)
        precondition(restored.fontSize == 40 && restored.speed == 12)
        let monitor = Engine(); monitor.cameraEnabled = false; monitor.microphoneEnabled = false
        recorder.engine = monitor
        _ = try await recorder.request(["action":"configure","width":1200,"height":800])
        precondition(recorder.engine === monitor, "output-only changes must preserve the monitoring engine")
        _ = try await recorder.request(["action":"configure","width":1000,"height":800])
        recorder.engine = nil
        recorder.error = "camera_permission"; recorder.monitorError = "camera_permission"
        try await recorder.prepareMonitoring()
        precondition(recorder.error.isEmpty && recorder.monitorError.isEmpty, "successful monitoring recovery must clear stale permission errors")
        // Preview changes must not stop an active capture or alter output dimensions.
        recorder.phase = "recording"
        let previewState = try await recorder.request(["action":"preview", "mirror":true, "layout":"fill", "position":"top-left"])
        precondition(previewState["mirror"] as? Bool == true)
        precondition(recorder.phase == "recording" && recorder.width == 1000 && recorder.height == 800)
        do { _ = try await recorder.request(["action":"preview", "layout":"invalid"]); fatalError("invalid preview accepted") }
        catch { precondition(error.localizedDescription == "invalid_preview") }
        recorder.phase = "idle"
        do { _ = try await recorder.request(["action":"configure", "cameraID":"missing-test-device", "width":1920]); fatalError("missing device accepted") }
        catch { precondition(error.localizedDescription == "device_missing") }
        precondition(recorder.width == 1000, "missing device must not partially apply configuration")
        let previewRestored = Recorder(preferences: preferences).snapshot()
        precondition(previewRestored["mirror"] as? Bool == true)
        precondition(previewRestored["previewLayout"] as? String == "fill")
        for region in [CGRect(x:-1200,y:40,width:600,height:400),CGRect(x:10,y:20,width:120,height:8)] {
            for position in ["top-left","top-right","bottom-left","bottom-right","manual"] {
                let rect=previewFrame(in:region,layout:"small",position:position,manual:CGPoint(x:-2,y:3))
                precondition(region.contains(rect), "camera preview must stay inside resized capture region")
                precondition(abs(rect.width/rect.height-16/9) < 0.001)
            }
            precondition(previewFrame(in:region,layout:"fill",position:"manual",manual:.zero)==region)
        }
        // Area selection never enters permission/setup work; hit testing follows lifecycle.
        _ = try await recorder.request(["action":"show-prompt"])
        precondition(recorder.promptVisible && !recorder.overlaysVisible)
        precondition(recorder.frame?.isVisible == false && recorder.prompter?.isVisible == true)
        precondition(recorder.promptText?.isEditable == true && recorder.prompter?.ignoresMouseEvents == false)
        _ = try await recorder.request(["action":"focus-prompt"])
        precondition(recorder.prompter?.firstResponder === recorder.promptText)
        precondition(recorder.promptResizers.count == 8 && recorder.promptResizers.allSatisfy { $0.parent === recorder.prompter }, "resize controls must remain ordered child windows during body activation")
        let orderedWindows = NSApplication.shared.orderedWindows
        if let bodyIndex = orderedWindows.firstIndex(where:{ $0 === recorder.prompter }) {
            precondition(recorder.promptResizers.allSatisfy { handle in
                orderedWindows.firstIndex(where:{ $0 === handle }).map { $0 < bodyIndex } ?? false
            }, "focused prompt must keep complete resize handles above its text body")
        }
        recorder.promptText?.string = "Native draft"
        recorder.textDidChange(Notification(name:NSText.didChangeNotification,object:recorder.promptText))
        precondition(preferences.string(forKey:"script") == "Native draft")
        _ = try await recorder.request(["action":"prompt","playing":true])
        precondition(recorder.promptText?.isEditable == true && recorder.prompter?.ignoresMouseEvents == false)
        _ = try await recorder.request(["action":"prompt","playing":false])
        precondition(recorder.promptText?.isEditable == true)
        _ = try await recorder.request(["action":"prompt","reset":true])
        precondition(recorder.promptText?.isEditable == true)
        precondition(promptDragExceeded(CGPoint(x:3,y:3)) == false)
        precondition(promptDragExceeded(CGPoint(x:6,y:0)) == true)
        let eventAnchor = promptEventPoint(CGPoint(x:20,y:80),windowOrigin:CGPoint(x:480,y:700))
        let queuedDrag = promptEventPoint(CGPoint(x:80,y:50),windowOrigin:CGPoint(x:480,y:700))
        precondition(promptDragExceeded(CGPoint(x:queuedDrag.x-eventAnchor.x,y:queuedDrag.y-eventAnchor.y)))
        precondition(queuedDrag == CGPoint(x:560,y:750), "queued events must retain their own screen position independent of current pointer")
        _ = try await recorder.request(["action":"interface","theme":"light"])
        precondition(recorder.theme == "light" && recorder.promptText?.textColor == recorder.promptForegroundColor)
        _ = try await recorder.request(["action":"interface","theme":"dark"])
        precondition(recorder.theme == "dark" && recorder.promptText?.textColor == recorder.promptForegroundColor)
        _ = try await recorder.request(["action":"prompt","opacity":0.25])
        precondition(recorder.promptOpacity == 0.25 && recorder.scroll?.layer?.backgroundColor?.alpha == 0.25)
        precondition(abs((recorder.promptBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? -1)-32/255) < 0.0001)
        precondition(recorder.promptText?.textColor?.alphaComponent == 1 && recorder.prompter?.alphaValue == 1)
        _ = try await recorder.request(["action":"interface","theme":"light"])
        precondition(recorder.scroll?.layer?.backgroundColor?.alpha == 0.25 && recorder.promptText?.textColor == recorder.promptForegroundColor)
        for opacity in [-0.1,1.1,Double.nan,Double.infinity] {
            do { _ = try await recorder.request(["action":"prompt","opacity":opacity]); fatalError("invalid opacity accepted") }
            catch { precondition(error.localizedDescription == "invalid_prompt_opacity") }
        }
        precondition(recorder.promptOpacity == 0.25)
        precondition(Recorder(preferences:preferences).promptOpacity == 0.25)
        _ = try await recorder.request(["action":"prompt","opacity":0.0])
        precondition(recorder.scroll?.layer?.backgroundColor?.alpha == 0 && recorder.prompter?.ignoresMouseEvents == false)
        precondition(recorder.promptText?.textColor?.alphaComponent == 1)
        precondition(recorder.scroll?.contentView.drawsBackground == false && recorder.scroll?.contentView.isOpaque == false)
        _ = try await recorder.request(["action":"hide-prompt"])
        let area = try await recorder.request(["action":"area"])
        precondition(recorder.engine == nil && recorder.phase == "idle")
        precondition(area["overlaysVisible"] as? Bool == true)
        precondition(!recorder.promptVisible && recorder.prompter?.isVisible == false)
        precondition(recorder.frame?.ignoresMouseEvents == false)
        precondition(recorder.frameHandle == nil, "the selected area must not create a three-dot drag handle")
        precondition(recorder.shades.count == 4)
        precondition(recorder.shades.allSatisfy { $0.ignoresMouseEvents && $0.isVisible })
        recorder.camera = true
        recorder.cameraAuthorization = { .notDetermined }
        _ = try await recorder.request(["action":"area"])
        precondition(recorder.engine == nil && recorder.phase == "idle", "Area must not request undetermined camera permission")
        recorder.cameraAuthorization = { .denied }
        _ = try await recorder.request(["action":"area"])
        precondition(recorder.engine == nil && recorder.phase == "idle", "Denied camera permission must not block area selection")
        recorder.camera = false
        let selected = recorder.region
        let shadeArea = recorder.shades.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
        precondition(abs(shadeArea + selected.width * selected.height - recorder.screen.frame.width * recorder.screen.frame.height) < recorder.screen.frame.width + recorder.screen.frame.height, "AppKit panel rounding must leave less than one logical pixel of area error")
        precondition(recorder.shades.allSatisfy { !$0.frame.intersects(selected.insetBy(dx:1,dy:1)) })
        for phase in ["preparing", "countdown", "starting", "recording", "paused", "saving"] {
            recorder.phase = phase
            precondition(recorder.frame?.ignoresMouseEvents == true)
            precondition(recorder.shades.allSatisfy { !$0.isVisible })
            do { _ = try await recorder.request(["action":"region","x":0]); fatalError("locked region moved") }
            catch { precondition(error.localizedDescription == "session_busy") }
        }
        recorder.phase = "idle"
        precondition(recorder.frame?.ignoresMouseEvents == false)
        do { _ = try await recorder.request(["action":"region","width":123.0,"height":123.0]); fatalError("invalid aspect accepted") }
        catch { precondition(error.localizedDescription == "invalid_region") }
        precondition(recorder.region == selected)
        let coords = recorder.uiRect(selected)
        _ = try await recorder.request(["action":"region","x":coords[0],"y":coords[1]])
        precondition(recorder.region == selected)
        _ = try await recorder.request(["action":"move-overlay","kind":"region","dx":100000.0,"dy":100000.0])
        precondition(recorder.screen.visibleFrame.contains(recorder.region), "interior movement must clamp to selected display")
        precondition(recorder.region.size == selected.size)
        recorder.phase = "countdown"
        _ = try await recorder.request(["action":"cancel"])
        precondition(recorder.frame?.ignoresMouseEvents == false)
        recorder.phase = "idle"
        _ = try await recorder.request(["action":"hide"])
        precondition(!recorder.overlaysVisible)
        precondition(recorder.shades.allSatisfy { !$0.isVisible })
        let promptBounds = CGRect(x:0,y:0,width:1200,height:900)
        let promptInitial = CGRect(x:300,y:300,width:640,height:200)
        for edge in ["left","right","top","bottom","top-left","top-right","bottom-left","bottom-right"] {
            let resized = resizedPrompt(promptInitial,edge:edge,delta:CGPoint(x:10000,y:-10000),bounds:promptBounds)
            precondition(promptBounds.contains(resized))
            precondition(resized.width >= 320 && resized.height >= 120)
            if edge == "left" || edge == "right" { precondition(resized.height == promptInitial.height) }
            if edge == "top" || edge == "bottom" { precondition(resized.width == promptInitial.width) }
        }
        _ = try await recorder.request(["action":"area"])
        _ = try await recorder.request(["action":"show-prompt"])
        precondition(recorder.promptResizers.count == 8)
        recorder.phase = "recording"
        recorder.playing = true
        recorder.promptText?.string = String(repeating:"Prompter playback preserves the reading position.\n",count:100)
        recorder.resizePrompter(CGRect(x:300,y:300,width:640,height:200))
        recorder.scroll?.contentView.scroll(to:CGPoint(x:0,y:80))
        recorder.resizePrompter(CGRect(x:300,y:300,width:420,height:280))
        precondition(recorder.prompter?.ignoresMouseEvents == false)
        precondition(recorder.promptResizers.allSatisfy { !$0.ignoresMouseEvents })
        precondition(recorder.playing && recorder.phase == "recording")
        recorder.beginPromptInteraction()
        precondition(!recorder.playing && recorder.phase == "recording")
        precondition(recorder.scroll?.contentView.bounds.origin.y == 80)
        recorder.promptText?.string = "Live correction"
        recorder.textDidChange(Notification(name:NSText.didChangeNotification,object:recorder.promptText))
        precondition(preferences.string(forKey:"script") == "Live correction")
        precondition(recorder.promptToolbarHeight(420) == 104)
        precondition(recorder.promptToolbarHeight(550) == 72)
        precondition(recorder.promptToolbarHeight(640) == 40)
        recorder.language = "en"
        precondition(recorder.promptToolbarHeight(320) == 136)
        recorder.language = "zh-CN"
        precondition(recorder.scroll?.contentView.bounds.origin.y == 80, "resizing must preserve reading offset")
        recorder.phase = "idle"
        _ = try await recorder.request(["action":"hide"])
        precondition(recorder.promptVisible, "hiding Area must preserve independent prompter")
        _ = try await recorder.request(["action":"hide-prompt"])
        precondition(recorder.promptResizers.allSatisfy { !$0.isVisible })
        // Restoration clamps saved windows after display changes and never resumes playback.
        let restoreSuite = suite + ".restore"
        let restorePrefs = UserDefaults(suiteName:restoreSuite)!
        defer { restorePrefs.removePersistentDomain(forName:restoreSuite) }
        restorePrefs.set(["width":1000,"height":800,"camera":false,"microphone":false,"displayID":UInt32.max],forKey:"recordingConfiguration")
        restorePrefs.set([-99999.0,99999.0,500.0,400.0],forKey:"regionFrame")
        restorePrefs.set([-99999.0,99999.0,540.0,220.0],forKey:"promptFrame")
        restorePrefs.set([-99999.0,99999.0,320.0,180.0],forKey:"cameraFrame")
        restorePrefs.set(true,forKey:"regionVisible"); restorePrefs.set(true,forKey:"promptVisible")
        let resumed = Recorder(preferences:restorePrefs)
        _ = try await resumed.request(["action":"restore-session"])
        precondition(resumed.phase == "idle" && !resumed.playing && resumed.engine == nil)
        precondition(resumed.overlaysVisible && resumed.promptVisible && resumed.corners.count == 8)
        precondition(resumed.screen.visibleFrame.contains(resumed.region))
        precondition(resumed.screen.visibleFrame.contains(resumed.prompter!.frame))
        precondition(resumed.screen.visibleFrame.contains(resumed.previewRect))
        precondition(resumed.displayID != UInt32.max)
        let prior = resumed.prompter!.frame
        _ = try await resumed.request(["action":"restore-session"])
        precondition(resumed.prompter!.frame == prior, "restoration must be idempotent")
        _ = try await resumed.request(["action":"hide"])
        _ = try await resumed.request(["action":"hide-prompt"])
        let hiddenRestored = Recorder(preferences:restorePrefs)
        precondition(!hiddenRestored.overlaysVisible && !hiddenRestored.promptVisible)
        restorePrefs.set(["width":1000,"height":800,"camera":true,"microphone":true],forKey:"recordingConfiguration")
        let savedDevices = Recorder(preferences:restorePrefs)
        precondition(savedDevices.camera && savedDevices.microphone, "existing device choices must survive changed first-use defaults")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = try VideoFile(directory:folder,name:"empty",width:320,height:240,includeAudio:false)
        precondition(empty.audio == nil)
        let emptyResult = await empty.finish(in:folder)
        precondition(emptyResult != "saved", "a video without video frames is not successful")
        let video = try VideoFile(directory:folder,name:"screen",width:320,height:240,includeAudio:false)
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixels) == kCVReturnSuccess)
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer,[])
        memset(CVPixelBufferGetBaseAddress(buffer),0,CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer,[])
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescriptionOut:&format) == noErr)
        let pacer = ScreenFramePacer()
        var paced: [CMSampleBuffer] = []
        for i in [0, 1, 4] {
            var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(i),timescale:30),decodeTimeStamp:.invalid)
            var sample: CMSampleBuffer?
            precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample) == noErr)
            try pacer.offer(sample!) { paced.append($0) }
        }
        try pacer.flush(until: CMTime(value: 8, timescale: 30)) { paced.append($0) }
        precondition(paced.count == 8, "idle source must still produce all 30 Hz frames")
        precondition(pacer.repeatedFrames == 5)
        for (index, sample) in paced.enumerated() {
            precondition(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value:Int64(index),timescale:30))
            precondition(CMSampleBufferGetDuration(sample) == CMTime(value:1,timescale:30))
            try video.append(sample,video:true,requireReady:true)
            try await Task.sleep(nanoseconds:40_000_000)
        }
        let saved = await video.finish(in:folder)
        precondition(saved == "saved", saved)
        let asset = AVURLAsset(url:folder.appendingPathComponent("screen.mp4"))
        let videos = try await asset.loadTracks(withMediaType:.video)
        let audios = try await asset.loadTracks(withMediaType:.audio)
        precondition(videos.count == 1 && audios.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        times.sort()
        precondition(times.count == 8 && reader.status == .completed, "encoded frames=\(times), reader=\(reader.status.rawValue), error=\(String(describing: reader.error))")
        for (index, time) in times.enumerated() { precondition(abs(time - Double(index)/30) < 0.0001, "encoded MP4 must retain fixed cadence") }
        let failureFolder = folder.appendingPathComponent("partial-save")
        try FileManager.default.createDirectory(at: failureFolder, withIntermediateDirectories: true)
        let engine = Engine()
        engine.directory = failureFolder
        engine.screenFile = try VideoFile(directory:failureFolder,name:"screen",width:320,height:240,includeAudio:false)
        engine.cameraFile = try VideoFile(directory:failureFolder,name:"camera",width:320,height:240,includeAudio:false)
        let sentinel = Data("existing-file-must-not-be-overwritten".utf8)
        try sentinel.write(to: failureFolder.appendingPathComponent("camera.mp4"))
        for sample in paced {
            try engine.screenFile?.append(sample,video:true,requireReady:true)
            try engine.cameraFile?.append(sample,video:true,requireReady:true)
            try await Task.sleep(nanoseconds:40_000_000)
        }
        engine.fail(ProbeError.message("injected_device_disconnect"))
        recorder.engine = engine; recorder.phase = "recording"
        await recorder.stop()
        precondition(recorder.phase == "partial", "one successful file must produce partial save")
        precondition(recorder.engine === engine, "stop must preserve the AV session for monitoring and retained save results")
        precondition(FileManager.default.fileExists(atPath:failureFolder.appendingPathComponent("screen.mp4").path))
        precondition(FileManager.default.fileExists(atPath:failureFolder.appendingPathComponent("camera.partial.mp4").path))
        let preserved = try Data(contentsOf:failureFolder.appendingPathComponent("camera.mp4"))
        precondition(preserved == sentinel, "failed finalization must never overwrite existing data")
        precondition(recorder.result["fatalError"] as? String == "injected_device_disconnect")
        let emptyEngine = Engine(); emptyEngine.directory = folder
        recorder.engine = emptyEngine; recorder.phase = "recording"
        await recorder.stop()
        precondition(recorder.phase == "failed", "no successful output must not report saved")
        print("PASS: lifecycle, cancellation, validation, silent MP4, encoded CFR, injected failure, partial-save preservation, total failure")
    }
}
