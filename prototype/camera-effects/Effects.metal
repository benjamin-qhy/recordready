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
