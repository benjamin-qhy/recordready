import AVFoundation
import Vision
import CoreImage
import MetalKit

struct BeautySettings {
    var enabled=false
    var smoothing:Float=0, slim:Float=0, front:Float=0, left:Float=0, right:Float=0
    var active:Bool {enabled && smoothing+slim+front+left+right > 0}
    var json:[String:Any] {["enabled":enabled,"smoothing":smoothing*100,"slim":slim*100,"front":front*100,"left":left*100,"right":right*100]}
    init(_ data:[String:Any] = [:]) {
        enabled=data["enabled"] as? Bool ?? false
        func percent(_ key:String)->Float { let n=(data[key] as? NSNumber)?.floatValue ?? 0; return n.isFinite ? min(100,max(0,n))/100:0 }
        smoothing=percent("smoothing");slim=percent("slim");front=percent("front");left=percent("left");right=percent("right")
    }
}
func beautyError(_ message:String)->NSError {NSError(domain:"RecordReady.Beauty",code:1,userInfo:[NSLocalizedDescriptionKey:message])}

final class BeautyRenderer {
    let device: MTLDevice
    let context: CIContext
    let commands: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    var cache: CVMetalTextureCache!
    var pool: CVPixelBufferPool?
    var dimensions = CGSize.zero
    let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!
    init() throws {
        guard let d=MTLCreateSystemDefaultDevice(), let q=d.makeCommandQueue() else { throw beautyError("Metal 不可用") }
        device=d; commands=q; context=CIContext(mtlDevice:d,options:[.cacheIntermediates:false])
        let source=beautyMetalSource
        let library=try d.makeLibrary(source:source,options:nil)
        guard let function=library.makeFunction(name:"effects") else { throw beautyError("着色器缺失") }
        pipeline=try d.makeComputePipelineState(function:function)
        guard CVMetalTextureCacheCreate(nil,nil,d,nil,&cache)==kCVReturnSuccess else { throw beautyError("纹理缓存创建失败") }
    }
    func allocate() throws -> CVPixelBuffer {
        var b:CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&b)==kCVReturnSuccess, let b else { throw beautyError("像素缓冲区创建失败") }
        return b
    }
    func setup(_ width:Int,_ height:Int) throws {
        guard dimensions != CGSize(width:width,height:height) else { return }
        let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else { throw beautyError("缓冲池创建失败") }
        dimensions=CGSize(width:width,height:height)
    }
    func texture(_ buffer:CVPixelBuffer) throws -> (CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,.bgra8Unorm,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&ref)==kCVReturnSuccess,
              let ref, let texture=CVMetalTextureGetTexture(ref) else { throw beautyError("纹理转换失败") }
        return (ref,texture)
    }
    func render(_ input:CVPixelBuffer, parameters:[SIMD4<Float>]) throws -> CVPixelBuffer {
        let width=CVPixelBufferGetWidth(input),height=CVPixelBufferGetHeight(input)
        try setup(width,height)
        let output=try allocate()
        let textures=try [input,output].map(texture)
        guard let command=commands.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw beautyError("GPU 命令创建失败") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(textures[0].1,index:0)
        encoder.setTexture(textures[1].1,index:1)
        parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
        let w=pipeline.threadExecutionWidth,h=min(8,pipeline.maxTotalThreadsPerThreadgroup/w)
        encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:h,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? beautyError("GPU 处理失败") }
        return output
    }
}

// Owned exclusively by Engine.queue. The original camera timestamps are preserved.
final class BeautyProcessor {
    var settings=BeautySettings()
    var renderer:BeautyRenderer?
    let landmarks=VNDetectFaceLandmarksRequest()
    let handler=VNSequenceRequestHandler()
    var oldParameters:[SIMD4<Float>]?
    func process(_ sample:CMSampleBuffer) throws -> CMSampleBuffer {
        guard settings.active, let input=CMSampleBufferGetImageBuffer(sample) else {oldParameters=nil;return sample}
        if renderer == nil {renderer=try BeautyRenderer()}
        try handler.perform([landmarks],on:input,orientation:.up)
        guard let face=landmarks.results?.max(by:{$0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height}) else {oldParameters=nil;return sample}
        var p=geometry(face,Float(CVPixelBufferGetWidth(input)),Float(CVPixelBufferGetHeight(input)),settings.slim)
        if let old=oldParameters,old.count==p.count,abs(old[1].x-p[1].x)<p[1].z*0.5 {
            for i in 1..<p.count where i != 5 && i != 6 {p[i]=old[i]*0.35+p[i]*0.65}
        }
        oldParameters=p
        let output=try renderer!.render(input,parameters:p)
        CVBufferPropagateAttachments(input,output)
        var description:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:output,formatDescriptionOut:&description)==noErr,let description else {throw beautyError("视频格式创建失败")}
        var timing=CMSampleTimingInfo(duration:CMSampleBufferGetDuration(sample),presentationTimeStamp:CMSampleBufferGetPresentationTimeStamp(sample),decodeTimeStamp:CMSampleBufferGetDecodeTimeStamp(sample))
        var result:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:output,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&result)==noErr,let result else {throw beautyError("视频帧创建失败")}
        return result
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
}

private let beautyMetalSource = #"""
#include <metal_stdlib>
using namespace metal;

float ellipse(float2 p, float4 region) {
    float d = length((p-region.xy)/max(region.zw,float2(1)));
    return 1.0-smoothstep(0.75,1.0,d);
}

// PROTOTYPE: inverse cheek displacement + edge-preserving smoothing + local fill light.
kernel void effects(texture2d<float,access::sample> source [[texture(0)]],
                    texture2d<float,access::write> output [[texture(1)]],
                    constant float4 *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 size=p[0].xy, q=float2(gid)+0.5, offset=0;
    for(int i=0;i<int(p[5].z);i++) {
        float4 c=p[7+i];
        float d=distance(q,c.xy)/max(c.w,1.0);
        float weight=pow(max(0.0,1.0-d*d),2.0);
        offset.x+=c.z*weight;
    }
    q+=offset;
    float2 uv=q/size;
    float4 original=source.sample(s,uv), color=original;
    if(p[5].y>0 && p[0].z>0) {
        float4 face=p[1];
        float amount=ellipse(q,float4(face.xy+face.zw*float2(0.5,0.48),face.zw*float2(0.48,0.52)));
        amount*=1-ellipse(q,p[2]); amount*=1-ellipse(q,p[3]); amount*=1-ellipse(q,p[4]);
        if(amount>0.001) {
            float3 sum=0; float total=0;
            float stepSize=max(1.0,face.z/100.0);
            for(int y=-2;y<=2;y++) for(int x=-2;x<=2;x++) {
                float3 other=source.sample(s,(q+float2(x,y)*stepSize)/size).rgb;
                float3 delta=other-original.rgb;
                float weight=exp(-float(x*x+y*y)/5.0-dot(delta,delta)/0.018);
                sum+=other*weight; total+=weight;
            }
            color.rgb=mix(original.rgb,sum/max(total,0.0001),amount*p[0].z*0.85);
        }
    }
    if(p[5].y>0 && (p[5].x>0 || p[5].w>0 || p[6].x>0)) {
        float4 face=p[1];
        float2 relative=(q-(face.xy+face.zw*float2(0.5,0.5)))/(face.zw*float2(0.55,0.60));
        float region=1-smoothstep(0.72,1.05,length(relative));
        // A broad 2D face-local light distribution, not reconstructed 3D geometry.
        float leftWeight=clamp(0.60-relative.x*0.65,0.12,1.0);
        float rightWeight=clamp(0.60+relative.x*0.65,0.12,1.0);
        float total=p[5].x+p[5].w*leftWeight+p[6].x*rightWeight;
        // Smoothly limit combined exposure while preserving independent light contributions.
        float amount=1.6*(1.0-exp(-total/1.6));
        amount*=region*(1.0-0.12*clamp(relative.y,0.0,1.0));
        float3 linear=pow(max(color.rgb,float3(0)),float3(2.2));
        float luminance=dot(linear,float3(0.2126,0.7152,0.0722));
        float highlightProtection=1.0-0.6*smoothstep(0.4,0.9,luminance);
        float gain=exp2(amount*1.15*highlightProtection);
        // Soft highlight rolloff keeps white at white instead of clipping a hard edge.
        linear=linear*gain/(1.0+linear*(gain-1.0));
        color.rgb=pow(max(linear,float3(0)),float3(1.0/2.2));
    }
    color.a=1;
    output.write(color,gid);
}

"""#

// Coalesces preview delivery so slow UI rendering never queues camera frames indefinitely.
final class CameraPreviewMailbox {
    private let lock=NSLock()
    private var latest:CMSampleBuffer?
    private var scheduled=false
    func submit(_ sample:CMSampleBuffer, deliver:@escaping (CMSampleBuffer)->Void) {
        lock.lock();latest=sample
        if scheduled {lock.unlock();return}
        scheduled=true;lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock();let frame=self.latest;self.latest=nil;self.scheduled=false;self.lock.unlock()
            if let frame {deliver(frame)}
        }
    }
}
