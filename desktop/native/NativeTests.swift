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
        var quitRequests = 0
        let delegate = QuitDelegate(original: nil) { quitRequests += 1 }
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        precondition(quitRequests == 1)
        delegate.allowed = true
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        for phase in ["preparing", "countdown", "starting", "recording", "saving"] {
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
