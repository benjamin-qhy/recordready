// THROWAWAY PROTOTYPE. No app integration, no microphone, no screen recording.
import AppKit
import AVFoundation
import Vision
import CoreImage
import MetalKit

struct Settings { var smoothing: Float = 0; var slim: Float = 0; var front: Float = 0; var left: Float = 0; var right: Float = 0; var hasLight: Bool { front > 0 || left > 0 || right > 0 } }
let outputRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RR_PROBE_OUTPUT"] ?? NSHomeDirectory()+"/Movies/RecordReady-Effects-Probe", isDirectory:true)
func fail(_ text:String) -> NSError { NSError(domain:"EffectsProbe",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }

final class Renderer {
    let device: MTLDevice
    let context: CIContext
    let commands: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    var cache: CVMetalTextureCache!
    var pool: CVPixelBufferPool?
    var dimensions = CGSize.zero
    let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!
    init() throws {
        guard let d=MTLCreateSystemDefaultDevice(), let q=d.makeCommandQueue() else { throw fail("Metal 不可用") }
        device=d; commands=q; context=CIContext(mtlDevice:d,options:[.cacheIntermediates:false])
        let resources=Bundle.main.resourceURL!
        let source=try String(contentsOf:resources.appendingPathComponent("Effects.metal"),encoding:.utf8)
        let library=try d.makeLibrary(source:source,options:nil)
        guard let function=library.makeFunction(name:"effects") else { throw fail("着色器缺失") }
        pipeline=try d.makeComputePipelineState(function:function)
        guard CVMetalTextureCacheCreate(nil,nil,d,nil,&cache)==kCVReturnSuccess else { throw fail("纹理缓存创建失败") }
    }
    func allocate() throws -> CVPixelBuffer {
        var b:CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&b)==kCVReturnSuccess, let b else { throw fail("像素缓冲区创建失败") }
        return b
    }
    func setup(_ width:Int,_ height:Int) throws {
        guard dimensions != CGSize(width:width,height:height) else { return }
        let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else { throw fail("缓冲池创建失败") }
        dimensions=CGSize(width:width,height:height)
    }
    func texture(_ buffer:CVPixelBuffer) throws -> (CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,.bgra8Unorm,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&ref)==kCVReturnSuccess,
              let ref, let texture=CVMetalTextureGetTexture(ref) else { throw fail("纹理转换失败") }
        return (ref,texture)
    }
    func render(_ input:CVPixelBuffer, parameters:[SIMD4<Float>]) throws -> CVPixelBuffer {
        let width=CVPixelBufferGetWidth(input),height=CVPixelBufferGetHeight(input)
        try setup(width,height)
        let output=try allocate()
        let textures=try [input,output].map(texture)
        guard let command=commands.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw fail("GPU 命令创建失败") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(textures[0].1,index:0)
        encoder.setTexture(textures[1].1,index:1)
        parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
        let w=pipeline.threadExecutionWidth,h=min(8,pipeline.maxTotalThreadsPerThreadgroup/w)
        encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:h,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? fail("GPU 处理失败") }
        return output
    }
}

final class Preview: MTKView, MTKViewDelegate {
    let imageContext: CIContext
    let commands: MTLCommandQueue
    var image: CIImage?
    init(renderer:Renderer) {
        imageContext=renderer.context; commands=renderer.commands
        super.init(frame:.zero,device:renderer.device)
        framebufferOnly=false; isPaused=true; enableSetNeedsDisplay=true
        colorPixelFormat = .bgra8Unorm; clearColor=MTLClearColorMake(0.06,0.07,0.09,1)
        delegate=self
    }
    required init(coder:NSCoder) { fatalError() }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    func draw(in view:MTKView) {
        guard let image, let drawable=currentDrawable,let command=commands.makeCommandBuffer() else { return }
        let rect=CGRect(origin:.zero,size:drawableSize)
        let scale=min(rect.width/image.extent.width,rect.height/image.extent.height)
        let scaled=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let placed=scaled.transformed(by:CGAffineTransform(translationX:(rect.width-scaled.extent.width)/2,y:(rect.height-scaled.extent.height)/2))
        let composite=placed.composited(over:CIImage(color:CIColor(red:0.06,green:0.07,blue:0.09)).cropped(to:rect))
        imageContext.render(composite,to:drawable.texture,commandBuffer:command,bounds:rect,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        command.present(drawable); command.commit()
    }
    func present(_ buffer:CVPixelBuffer) { image=CIImage(cvPixelBuffer:buffer); needsDisplay=true }
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let renderer:Renderer
    let session=AVCaptureSession()
    let queue=DispatchQueue(label:"effects-probe.camera",qos:.userInitiated)
    var settings=Settings()
    let settingsLock=NSLock()
    var pendingSettings:Settings?
    let landmarks=VNDetectFaceLandmarksRequest()
    let handler=VNSequenceRequestHandler()
    var faceParameters:[SIMD4<Float>]?
    var lastFaceTime:Double=0
    var frames=0, captureDrops=0
    var firstTime=0.0, reportTime=0.0
    var durations:[Double]=[], landmarkDurations:[Double]=[], renderDurations:[Double]=[]
    var latest:CVPixelBuffer?
    var onFrame:((CVPixelBuffer)->Void)?
    var onStatus:((String)->Void)?
    var onRecording:((Bool)->Void)?
    let previewLock=NSLock()
    var pendingPreview:CVPixelBuffer?
    var previewScheduled=false
    var writer:AVAssetWriter?
    var writerInput:AVAssetWriterInput?
    var adaptor:AVAssetWriterInputPixelBufferAdaptor?
    var writerStart:CMTime?
    var writerURL:URL?
    var writerCount=0
    var writerDrops=0
    var lastStats:[String:Any]=[:]
    init(renderer:Renderer) {
        self.renderer=renderer; super.init()
    }
    func start() {
        AVCaptureDevice.requestAccess(for:.video) { allowed in
            guard allowed else { self.status("摄像头权限未获准。请在系统设置中允许 Effects Probe。"); return }
            self.queue.async {
                do {
                    guard let camera=AVCaptureDevice.default(for:.video) else { throw fail("未找到摄像头") }
                    self.session.beginConfiguration(); self.session.sessionPreset = .hd1280x720
                    let input=try AVCaptureDeviceInput(device:camera)
                    guard self.session.canAddInput(input) else { self.session.commitConfiguration(); throw fail("无法添加摄像头") }
                    self.session.addInput(input)
                    let output=AVCaptureVideoDataOutput()
                    output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                    output.alwaysDiscardsLateVideoFrames=true
                    output.setSampleBufferDelegate(self,queue:self.queue)
                    guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw fail("无法添加视频输出") }
                    self.session.addOutput(output); self.session.commitConfiguration()
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where:{$0.minFrameRate<=30 && $0.maxFrameRate>=30}) {
                        try camera.lockForConfiguration()
                        camera.activeVideoMinFrameDuration=CMTime(value:1,timescale:30)
                        camera.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
                        camera.unlockForConfiguration()
                    }
                    self.session.startRunning(); self.status("摄像头：\(camera.localizedName) · 准备画面…")
                } catch { self.status(error.localizedDescription) }
            }
        }
    }
    func status(_ text:String) { DispatchQueue.main.async { self.onStatus?(text) } }
    func configure(_ value:Settings) {
        settingsLock.lock(); pendingSettings=value; settingsLock.unlock()
    }
    func publish(_ buffer:CVPixelBuffer) {
        previewLock.lock();pendingPreview=buffer
        let schedule = !previewScheduled;previewScheduled=true;previewLock.unlock()
        guard schedule else {return}
        DispatchQueue.main.async {
            self.previewLock.lock();let frame=self.pendingPreview;self.pendingPreview=nil
            self.previewScheduled=false;self.previewLock.unlock()
            if let frame {self.onFrame?(frame)}
        }
    }
    func resetStats() {
        frames=0;captureDrops=0;firstTime=0;reportTime=0
        durations=[];landmarkDurations=[];renderDurations=[]
    }
    func points(_ region:VNFaceLandmarkRegion2D?,_ face:VNFaceObservation,_ width:Float,_ height:Float) -> [SIMD2<Float>] {
        guard let region else { return [] }
        let b=face.boundingBox
        let bx=Float(b.minX),by=Float(b.minY),bw=Float(b.width),bh=Float(b.height)
        return region.normalizedPoints.map { point in
            let x=(bx+Float(point.x)*bw)*width
            let y=(Float(1)-by-Float(point.y)*bh)*height
            return SIMD2<Float>(x,y)
        }
    }
    func geometry(_ face:VNFaceObservation,_ width:Float,_ height:Float,_ slim:Float) -> [SIMD4<Float>] {
        let b=face.boundingBox
        let rect=SIMD4<Float>(Float(b.minX)*width,Float(1-b.maxY)*height,Float(b.width)*width,Float(b.height)*height)
        func feature(_ region:VNFaceLandmarkRegion2D?,_ fallback:SIMD2<Float>,_ radius:SIMD2<Float>) -> SIMD4<Float> {
            let ps=points(region,face,width,height)
            let center=ps.isEmpty ? fallback : ps.reduce(SIMD2<Float>.zero,+)/Float(ps.count)
            return SIMD4<Float>(center.x,center.y,radius.x*rect.z,radius.y*rect.w)
        }
        let l=face.landmarks
        var p=[SIMD4<Float>(width,height,settings.smoothing,slim),rect,
            feature(l?.leftEye,SIMD2(rect.x+rect.z*0.3,rect.y+rect.w*0.4),SIMD2(0.19,0.12)),
            feature(l?.rightEye,SIMD2(rect.x+rect.z*0.7,rect.y+rect.w*0.4),SIMD2(0.19,0.12)),
            feature(l?.outerLips,SIMD2(rect.x+rect.z*0.5,rect.y+rect.w*0.76),SIMD2(0.27,0.13)),
            SIMD4<Float>(settings.front,1,0,settings.left), SIMD4<Float>(settings.right,0,0,0)]
        let yaw=abs(face.yaw?.floatValue ?? 0)
        let poseFade=max(0,1-yaw/0.65)
        let contour=points(l?.faceContour,face,width,height)
        // Four contour controls per side at most. All displacement is horizontal.
        for (index,point) in contour.enumerated() where index%2==0 {
            let nx=(point.x-rect.x)/rect.z,ny=(point.y-rect.y)/rect.w
            guard abs(nx-0.5)>0.23,ny>0.28,ny<0.86 else { continue }
            let delta=(nx<0.5 ? -1:Float(1))*rect.z*0.035*slim*poseFade
            p.append(SIMD4<Float>(point.x-delta,point.y,delta,rect.z*0.24))
            if p.count==15 { break }
        }
        p[5].z=Float(p.count-7)
        return p
    }
    func captureOutput(_ output:AVCaptureOutput,didDrop sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) { captureDrops+=1 }
    func captureOutput(_ output:AVCaptureOutput,didOutput sample:CMSampleBuffer,from connection:AVCaptureConnection) {
        autoreleasepool {
            guard let input=CMSampleBufferGetImageBuffer(sample) else { return }
            settingsLock.lock();let next=pendingSettings;pendingSettings=nil;settingsLock.unlock()
            if let next,writer==nil {settings=next;faceParameters=nil;resetStats()}
            let began=CACurrentMediaTime(),w=Float(CVPixelBufferGetWidth(input)),h=Float(CVPixelBufferGetHeight(input))
            do {
                var face:VNFaceObservation?
                if settings.smoothing>0 || settings.slim>0 || settings.hasLight {
                    try handler.perform([landmarks],on:input,orientation:.up)
                    face=landmarks.results?.max(by:{$0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height})
                }
                let faceDone=CACurrentMediaTime()
                var p=[SIMD4<Float>(w,h,settings.smoothing,settings.slim)]+Array(repeating:SIMD4<Float>.zero,count:6)
                p[5]=SIMD4(settings.front,0,0,settings.left)
                p[6]=SIMD4(settings.right,0,0,0)
                if let face {
                    p=geometry(face,w,h,settings.slim)
                    if let old=faceParameters,old.count==p.count,began-lastFaceTime<0.15,
                       abs(old[1].x-p[1].x)<p[1].z*0.5 {
                        for i in 1..<p.count where i != 5 && i != 6 { p[i]=old[i]*0.35+p[i]*0.65 }
                    }
                    faceParameters=p; lastFaceTime=began
                } else { faceParameters=nil }
                let processed:CVPixelBuffer
                if settings.smoothing==0 && settings.slim==0 && !settings.hasLight { processed=input }
                else { processed=try renderer.render(input,parameters:p) }
                latest=processed
                append(processed,CMSampleBufferGetPresentationTimeStamp(sample))
                publish(processed)
                let end=CACurrentMediaTime()
                frames+=1; if firstTime==0 {firstTime=began}
                durations.append((end-began)*1000); landmarkDurations.append((faceDone-began)*1000)
                renderDurations.append((end-faceDone)*1000)
                if durations.count>300 { durations.removeFirst();landmarkDurations.removeFirst();renderDurations.removeFirst() }
                if end-reportTime>1 {
                    reportTime=end
                    let fps=Double(max(0,frames-1))/max(0.001,began-firstTime), sorted=durations.sorted()
                    func avg(_ a:[Double])->Double {a.reduce(0,+)/Double(max(1,a.count))}
                    let p95=sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]
                    lastStats=["frames":frames,"fps":fps,"captureDrops":captureDrops,"processingP95MS":p95,
                        "landmarksMeanMS":avg(landmarkDurations),"renderMeanMS":avg(renderDurations),
                        "smoothing":settings.smoothing,"slim":settings.slim,"frontLight":settings.front,"leftLight":settings.left,"rightLight":settings.right,"width":w,"height":h,
                        "faceDetected":face != nil,"os":ProcessInfo.processInfo.operatingSystemVersionString]
                    let suffix=writer == nil ? "":" · 正在录制样片"
                    status(String(format:"%d × %d · %.1f fps · P95 %.1f ms · 丢帧 %d\n关键点 %.1f / 渲染 %.1f ms · %@%@",Int(w),Int(h),fps,p95,captureDrops,avg(landmarkDurations),avg(renderDurations),face == nil ? "无人脸或未启用人脸效果":"检测到人脸",suffix))
                    try? FileManager.default.createDirectory(at:outputRoot,withIntermediateDirectories:true)
                    let data=try JSONSerialization.data(withJSONObject:lastStats,options:[.prettyPrinted,.sortedKeys])
                    try data.write(to:outputRoot.appendingPathComponent("latest-metrics.json"),options:.atomic)
                }
            } catch {
                status("处理失败：\(error.localizedDescription)")
                if writer != nil {finishRecording()}
            }
        }
    }
    func record() { queue.async {
        guard self.writer==nil,let latest=self.latest else {return}
        do {
            try FileManager.default.createDirectory(at:outputRoot,withIntermediateDirectories:true)
            let url=outputRoot.appendingPathComponent("sample-\(Int(Date().timeIntervalSince1970)).mp4")
            let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
            let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:CVPixelBufferGetWidth(latest),AVVideoHeightKey:CVPixelBufferGetHeight(latest)])
            input.expectsMediaDataInRealTime=true; writer.add(input)
            let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:nil)
            guard writer.startWriting() else {throw writer.error ?? fail("无法开始录制")}
            writer.startSession(atSourceTime:.zero)
            self.writer=writer;self.writerInput=input;self.adaptor=adaptor;self.writerStart=nil;self.writerURL=url;self.writerCount=0;self.writerDrops=0
            DispatchQueue.main.async {self.onRecording?(true)}
        } catch {self.status(error.localizedDescription)}
    } }
    func append(_ buffer:CVPixelBuffer,_ time:CMTime) {
        guard let writer,let input=writerInput,let adaptor else {return}
        if writerStart==nil {writerStart=time}
        let pts=time-writerStart!
        if pts.seconds>=5 {finishRecording();return}
        guard input.isReadyForMoreMediaData else {writerDrops+=1;return}
        if adaptor.append(buffer,withPresentationTime:pts) {writerCount+=1}
        else {status(writer.error?.localizedDescription ?? "样片写入失败");finishRecording()}
    }
    func finishRecording(completion: (() -> Void)? = nil) {
        guard let writer,let url=writerURL else {completion?();return}
        writerInput?.markAsFinished()
        var report=lastStats;report["sampleFrames"]=writerCount;report["writerDrops"]=writerDrops
        self.writer=nil;writerInput=nil;adaptor=nil;writerStart=nil
        writer.finishWriting {
            DispatchQueue.main.async {self.onRecording?(false)}
            if writer.status == .completed {
                if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:url.deletingPathExtension().appendingPathExtension("json"))}
                self.status("样片已保存：\(url.path)")
            } else {self.status(writer.error?.localizedDescription ?? "样片保存失败")}
            completion?()
        }
    }
    func stop(completion:@escaping ()->Void) {
        // Stop capture from a different queue: stopping on its callback queue can deadlock.
        DispatchQueue.global(qos:.userInitiated).async {
            self.session.stopRunning()
            self.queue.async {self.finishRecording(completion:completion)}
        }
    }
    func snapshot() { queue.async {
        guard let latest=self.latest else {return}
        do {
            try FileManager.default.createDirectory(at:outputRoot,withIntermediateDirectories:true)
            try self.renderer.context.writePNGRepresentation(of:CIImage(cvPixelBuffer:latest),to:outputRoot.appendingPathComponent("preview.png"),format:.RGBA8,colorSpace:self.renderer.colorSpace)
            self.status("已保存当前预览：\(outputRoot.path)/preview.png")
        } catch {self.status(error.localizedDescription)}
    } }
}

final class App: NSObject, NSApplicationDelegate {
    var nativeStatus:NSTextField!
    var nativePanel:NSButton!, centerStage:NSButton!, customToggle:NSButton!
    var effectsTimer:Timer?
    var recording=false
    var window:NSWindow!
    var camera:Camera!
    var smoothing:NSSlider!, slim:NSSlider!, front:NSSlider!, left:NSSlider!, right:NSSlider!
    var smoothingLabel:NSTextField!, slimLabel:NSTextField!, frontLabel:NSTextField!, leftLabel:NSTextField!, rightLabel:NSTextField!, status:NSTextField!
    func applicationDidFinishLaunching(_ notification:Notification) {
        do {
            let renderer=try Renderer()
            if CommandLine.arguments.contains("--self-check") {try selfCheck(renderer);NSApp.terminate(nil);return}
            camera=Camera(renderer:renderer)
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:930),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="RecordReady · 系统效果与通用美颜原型";window.center();window.minSize=NSSize(width:800,height:840)
            let root=NSStackView();root.orientation = .vertical;root.spacing=12;root.edgeInsets=NSEdgeInsets(top:16,left:20,bottom:16,right:20)
            window.contentView=root
            let title=NSTextField(labelWithString:"macOS 系统摄像头效果 · 优先使用")
            title.font = .systemFont(ofSize:18,weight:.semibold); root.addArrangedSubview(title)
            let preview=Preview(renderer:renderer);preview.translatesAutoresizingMaskIntoConstraints=false
            root.addArrangedSubview(preview)
            preview.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant:360).isActive=true
            AVCaptureDevice.centerStageControlMode = .cooperative
            nativePanel=NSButton(title:"打开 macOS 摄像头效果",target:self,action:#selector(openNativeEffects))
            centerStage=NSButton(checkboxWithTitle:"人物自动居中",target:self,action:#selector(toggleCenterStage))
            let nativeRow=NSStackView(views:[nativePanel,centerStage]);nativeRow.spacing=18;root.addArrangedSubview(nativeRow)
            let nativeHint=NSTextField(wrappingLabelWithString:"在系统面板调整：取景／缩放、摄影室灯光、屏幕补光、人像虚化、背景替换和手势效果。可用项目由系统与摄像头决定。")
            nativeHint.preferredMaxLayoutWidth=900;root.addArrangedSubview(nativeHint)
            nativeStatus=NSTextField(wrappingLabelWithString:"正在读取系统效果…")
            nativeStatus.font = .systemFont(ofSize:12);nativeStatus.heightAnchor.constraint(equalToConstant:40).isActive=true
            root.addArrangedSubview(nativeStatus)
            customToggle=NSButton(checkboxWithTitle:"启用通用美颜与补光（独立于系统效果）",target:self,action:#selector(change))
            customToggle.state = .off;root.addArrangedSubview(customToggle)
            func sliderRow(_ name:String,_ action:Selector) -> (NSSlider,NSTextField) {
                let label=NSTextField(labelWithString:name+" 0%")
                label.widthAnchor.constraint(equalToConstant:130).isActive=true
                let slider=NSSlider(value:0,minValue:0,maxValue:100,target:self,action:action);slider.isContinuous=true
                slider.setAccessibilityLabel(name)
                let row=NSStackView(views:[label,slider]);row.spacing=16
                root.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true
                return (slider,label)
            }
            (smoothing,smoothingLabel)=sliderRow("磨皮",#selector(change))
            (slim,slimLabel)=sliderRow("瘦脸",#selector(change))
            (front,frontLabel)=sliderRow("正面柔光",#selector(change))
            (left,leftLabel)=sliderRow("画面左前柔光",#selector(change))
            (right,rightLabel)=sliderRow("画面右前柔光",#selector(change))
            let reset=NSButton(title:"重置通用效果",target:self,action:#selector(reset))
            let record=NSButton(title:"录制 5 秒样片（无声）",target:self,action:#selector(recordSample))
            let snapshot=NSButton(title:"保存当前画面",target:self,action:#selector(snapshot))
            let folder=NSButton(title:"打开结果目录",target:self,action:#selector(openFolder))
            let row=NSStackView(views:[reset,record,snapshot,folder]);row.spacing=14;root.addArrangedSubview(row)
            status=NSTextField(wrappingLabelWithString:"点击系统授权提示中的“允许”，开始真实摄像头预览。")
            status.font = .monospacedSystemFont(ofSize:12,weight:.regular)
            status.heightAnchor.constraint(equalToConstant:44).isActive=true
            root.addArrangedSubview(status)
            let note=NSTextField(labelWithString:"软件补光：随人脸调整局部亮度，不能恢复真实灯光投影。画面仅在本机，录制按钮保存 5 秒无声样片。")
            note.textColor = .secondaryLabelColor;note.font = .systemFont(ofSize:11);root.addArrangedSubview(note)
            camera.onFrame={[weak preview] in preview?.present($0)}
            camera.onStatus={[weak self] in self?.status.stringValue=$0}
            camera.onRecording={[weak self] active in
                self?.recording=active;self?.refreshControls()
                reset.isEnabled = !active;record.isEnabled = !active
            }
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            refreshControls()
            effectsTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) {[weak self] _ in self?.refreshNativeStatus()}
            refreshNativeStatus()
            camera.start()
        } catch {
            fputs("\(error)\n",stderr)
            if CommandLine.arguments.contains("--self-check") {exit(1)}
            let alert=NSAlert(error:error);alert.runModal();NSApp.terminate(nil)
        }
    }
    @objc func openNativeEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
    @objc func toggleCenterStage() { AVCaptureDevice.isCenterStageEnabled = centerStage.state == .on;refreshNativeStatus() }
    func refreshNativeStatus() {
        guard let device=AVCaptureDevice.default(for:.video) else {nativeStatus.stringValue="未找到摄像头";centerStage.isEnabled=false;return}
        let format=device.activeFormat
        centerStage.state=AVCaptureDevice.isCenterStageEnabled ? .on:.off
        centerStage.isEnabled=format.isCenterStageSupported && !recording
        func state(_ supported:Bool,_ active:Bool)->String {supported ? (active ? "已生效":"关闭") : "不支持"}
        var text="人物居中：\(state(format.isCenterStageSupported,device.isCenterStageActive)) · 人像虚化：\(state(format.isPortraitEffectSupported,device.isPortraitEffectActive)) · 摄影室灯光：\(state(format.isStudioLightSupported,device.isStudioLightActive))"
        if #available(macOS 15.0, *) {text += " · 背景替换：\(state(format.isBackgroundReplacementSupported,device.isBackgroundReplacementActive))"}
        text += "\n取景、屏幕补光和手势效果请以系统面板为准。"
        if device.isStudioLightActive && customToggle.state == .on && (front.doubleValue+left.doubleValue+right.doubleValue)>0 {text += " 当前同时使用两种补光，请留意亮度。"}
        nativeStatus.stringValue=text
    }
    func refreshControls() {
        let enabled=customToggle.state == .on && !recording
        for slider in [smoothing,slim,front,left,right] {slider?.isEnabled=enabled}
        customToggle.isEnabled = !recording;nativePanel.isEnabled = !recording
        refreshNativeStatus()
    }
    @objc func change() {
        smoothingLabel.stringValue="磨皮 \(smoothing.integerValue)%";slimLabel.stringValue="瘦脸 \(slim.integerValue)%"
        frontLabel.stringValue="正面柔光 \(front.integerValue)%"
        leftLabel.stringValue="画面左前柔光 \(left.integerValue)%"
        rightLabel.stringValue="画面右前柔光 \(right.integerValue)%"
        refreshControls()
        guard customToggle.state == .on else {camera.configure(Settings());return}
        camera.configure(Settings(smoothing:Float(smoothing.integerValue)/100,slim:Float(slim.integerValue)/100,front:Float(front.integerValue)/100,left:Float(left.integerValue)/100,right:Float(right.integerValue)/100))
    }
    @objc func reset() {customToggle.state = .off;smoothing.doubleValue=0;slim.doubleValue=0;front.doubleValue=0;left.doubleValue=0;right.doubleValue=0;change()}
    @objc func recordSample() {camera.record()}
    @objc func snapshot() {camera.snapshot()}
    @objc func openFolder() {try? FileManager.default.createDirectory(at:outputRoot,withIntermediateDirectories:true);NSWorkspace.shared.open(outputRoot)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let camera else {return .terminateNow}
        effectsTimer?.invalidate()
        camera.stop {DispatchQueue.main.async {sender.reply(toApplicationShouldTerminate:true)}}
        return .terminateLater
    }
}

func selfCheck(_ renderer:Renderer) throws {
    try renderer.setup(640,360)
    let input=try renderer.allocate()
    renderer.context.render(CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:640,height:360)),to:input)
    var p=[SIMD4<Float>(640,360,0,0)]+Array(repeating:SIMD4<Float>.zero,count:6)
    func pixel(_ buffer:CVPixelBuffer,_ x:Int,_ y:Int)->Int {
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let base=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
        return Int(base[y*CVPixelBufferGetBytesPerRow(buffer)+x*4+2])
    }
    let bypass=try renderer.render(input,parameters:p)
    guard abs(pixel(bypass,320,180)-pixel(input,320,180))<=1 else {throw fail("零强度改变了原图")}
    p[1]=SIMD4<Float>(160,40,320,280)
    p[5]=SIMD4<Float>(1,1,0,0)
    let front=try renderer.render(input,parameters:p)
    guard pixel(front,320,180)>pixel(input,320,180)+15 else {throw fail("正面补光未提亮脸部")}
    guard abs(pixel(front,10,10)-pixel(input,10,10))<=1 else {throw fail("局部补光影响了远处背景")}
    p[5].x=0; p[5].w=1
    let left=try renderer.render(input,parameters:p)
    guard pixel(left,260,180)>pixel(left,380,180)+5 else {throw fail("左侧光位没有方向差异")}
    p[5].w=0; p[6].x=1
    let right=try renderer.render(input,parameters:p)
    guard pixel(right,380,180)>pixel(right,260,180)+5 else {throw fail("右侧光位没有方向差异")}
    p[5].x=1; p[5].w=1; p[6].x=1
    let combined=try renderer.render(input,parameters:p)
    guard pixel(combined,320,180)>pixel(front,320,180), pixel(combined,320,180)<240 else {throw fail("多光源叠加无效或过亮")}
    guard abs(pixel(combined,260,180)-pixel(combined,380,180))<=2 else {throw fail("等强度左右补光不对称")}
    p[5].y=0
    let absent=try renderer.render(input,parameters:p)
    guard abs(pixel(absent,320,180)-pixel(input,320,180))<=1 else {throw fail("无人脸时补光未关闭")}
    print("PASS: Metal 编译、原图旁路、正面提亮、左右光位、多光叠加与亮度上限、背景保护、无人脸关闭。")
}

let app=NSApplication.shared
let delegate=App()
app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
