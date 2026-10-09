#include <metal_stdlib>
using namespace metal;
constant uint MaxLights = 16;
struct Vertex {
    packed_float3 position, normal;
    uchar4 color;
    packed_float2 uv;
    packed_float4 weights;
    uchar4 bones;
};
struct Uniforms {
    float4x4 world, view, projection, envMatrix;
    float4 material, surface, ambient, fogColor;
    float4 fog, alpha, window, envParams, envColor, textureRegion;
    uint4 flags;
    float4 lightParams[MaxLights], lightPosition[MaxLights];
    float4 lightDirection[MaxLights], lightColor[MaxLights];
};
struct Varying {
    float4 position [[position]];
    float4 color, envColor;
    float2 uv, envUV;
    float fog;
    float pointSize [[point_size]];
};
vertex Varying rw_vertex(uint id [[vertex_id]], device const Vertex *vertices [[buffer(0)]],
                         constant Uniforms &u [[buffer(1)]], device const float4x4 *bones [[buffer(2)]])
{
    Vertex v = vertices[id];
    Varying o;
    float4 p = float4(v.position, 1.0);
    float3 normal = float3(v.normal);
    if(u.flags.z != 0){
        float4x4 skin = bones[v.bones.x]*v.weights.x + bones[v.bones.y]*v.weights.y
                     + bones[v.bones.z]*v.weights.z + bones[v.bones.w]*v.weights.w;
        p = skin*p;
        normal = (skin*float4(normal, 0.0)).xyz;
    }
    float4 vertexColor = float4(v.color)/255.0;
    if(u.flags.y != 0){
        // Screen coordinates use the top left origin, as do Metal textures.
        float w = v.normal.x;
        o.position = float4((2.0*p.x/u.window.x-1.0)*w, (1.0-2.0*p.y/u.window.y)*w, p.z*w, w);
    }else{
        p = u.world*p;
        normal = (u.world*float4(normal, 0.0)).xyz;
        o.position = u.projection*u.view*p;
    }
    if(u.flags.x != 0){
        float3 light = u.ambient.rgb*u.surface.x;
        for(uint i=0; i<MaxLights; i++){
            float type = u.lightParams[i].x;
            if(type == 0.0) break;
            float3 dir;
            float atten = 1.0;
            if(type == 1.0) dir = -u.lightDirection[i].xyz;
            else {
                float3 delta = u.lightPosition[i].xyz-p.xyz;
                float distance = length(delta);
                dir = delta/max(distance, 0.00001);
                atten = max(0.0, 1.0-distance/u.lightParams[i].y);
                if(type == 3.0){
                    float cone = -u.lightParams[i].z;
                    float falloff = (dot(-dir, u.lightDirection[i].xyz)-cone)/max(1.0-cone, 0.00001);
                    atten *= falloff < 0.0 ? 0.0 : max(falloff, u.lightParams[i].w);
                }
            }
            light += max(0.0, dot(normal, dir))*u.lightColor[i].rgb*atten*u.surface.z;
        }
        vertexColor.rgb = clamp(vertexColor.rgb+light, 0.0, 1.0);
    }
    o.envColor = max(vertexColor, float4(u.envParams.z))*u.envColor;
    o.color = vertexColor*u.material;
    o.uv = v.uv;
    o.envUV = (u.envMatrix*float4(normal, 1.0)).xy;
    o.fog = u.fog.z != 0.0 ? clamp((u.fog.y-o.position.w)/max(u.fog.y-u.fog.x, 0.00001), 0.0, 1.0) : 1.0;
    o.pointSize = 1.0;
    return o;
}
fragment float4 rw_fragment(Varying v [[stage_in]], constant Uniforms &u [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler sam [[sampler(0)]],
                            texture2d<float> env [[texture(1)]], sampler envSam [[sampler(1)]])
{
    float4 color = v.color*tex.sample(sam, v.uv*u.textureRegion.xy+u.textureRegion.zw);
    color.rgb = mix(u.fogColor.rgb, color.rgb, v.fog);
    if(u.flags.w != 0){
        float4 reflection = v.envColor*u.envParams.x*env.sample(envSam, v.envUV);
        reflection.rgb *= v.fog;
        color.rgb = color.rgb*color.a + reflection.rgb*max(color.a, u.envParams.y);
    }
    if((u.alpha.x == 1.0 && color.a < u.alpha.y) ||
       (u.alpha.x == 2.0 && color.a >= u.alpha.y)) discard_fragment();
    return color;
}

struct ClearVarying { float4 position [[position]]; float4 color; };
vertex ClearVarying clear_vertex(uint id [[vertex_id]],constant float4 &color [[buffer(1)]])
{
    const float2 p[3]={float2(-1,1),float2(3,1),float2(-1,-3)};
    return {float4(p[id],1,1),color};
}
fragment float4 clear_fragment(ClearVarying v [[stage_in]]) { return v.color; }
