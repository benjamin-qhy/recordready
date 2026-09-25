import Foundation
import AVFoundation
import Darwin

// Synthetic samples only. The caller must provide a disposable mounted volume.
@main struct DiskFullTests {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let capacity = try directory.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity ?? 0
        precondition(capacity > 0 && capacity <= 128 * 1024 * 1024, "requires small disposable volume")
        let sentinel = Data("previous-successful-output".utf8)
        let preserved = directory.appendingPathComponent("previous.mp4")
        try sentinel.write(to: preserved)
        let video = try VideoFile(directory: directory, name: "screen", width: 640, height: 480, includeAudio: false)
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
        let buffer = pixels!
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        func append(_ index: Int) throws {
            CVPixelBufferLockBaseAddress(buffer, [])
            arc4random_buf(CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
            try video.append(sample!, video: true)
        }
        for i in 0..<30 { try append(i); try await Task.sleep(nanoseconds: 20_000_000) }
        // Write real bytes, not sparse truncation, until this volume returns ENOSPC.
        let fd = open(directory.appendingPathComponent("filler").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        precondition(fd >= 0)
        let chunk = [UInt8](repeating: 0x5a, count: 1024 * 1024)
        var exhausted = false
        for _ in 0..<128 {
            let count = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count < 0 { exhausted = errno == ENOSPC; break }
        }
        close(fd)
        precondition(exhausted, "must observe real ENOSPC on disposable volume")
        var writeFailed = false
        for i in 30..<180 {
            do { try append(i) } catch { writeFailed = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let result = await video.finish(in: directory)
        precondition(result != "saved", "full-volume writer must not report saved")
        let retained = try Data(contentsOf: preserved)
        precondition(retained == sentinel, "existing output must be preserved")
        print("PASS: real ENOSPC on disposable volume; appendFailure=\(writeFailed); save not reported successful; existing output preserved")
    }
}
