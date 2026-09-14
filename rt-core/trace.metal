// SPDX-License-Identifier: MIT
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;
struct InputRay { float4 origin; float4 direction; };
struct Hit { float distance; uint primitive; uint hit; float reserved; };
kernel void trace_triangles(instance_acceleration_structure scene [[buffer(0)]],
                           device const InputRay *inputs [[buffer(1)]],
                           device Hit *hits [[buffer(2)]],
                           constant uint &count [[buffer(3)]],
                           uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    ray r;
    r.origin = inputs[i].origin.xyz;
    r.direction = inputs[i].direction.xyz;
    r.min_distance = inputs[i].origin.w;
    r.max_distance = inputs[i].direction.w;
    intersector<triangle_data,instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    auto result = query.intersect(r, scene);
    bool found = result.type != intersection_type::none;
    hits[i] = {found ? result.distance : -1.0f,
               found ? result.primitive_id+result.user_instance_id : 0xffffffffu, uint(found), 0.0f};
}

struct VisibilitySettings { float4 sun; float ao_distance; float ray_bias; uint samples; uint seed; };
static float random01(thread uint &state) {
    state ^= state >> 16; state *= 0x7feb352du; state ^= state >> 15; state *= 0x846ca68bu; state ^= state >> 16;
    return float(state >> 8) * (1.0f/16777216.0f);
}
static float3 around(float3 normal, float x, float y, float z) {
    float3 tangent = normalize(cross(abs(normal.y)<.99f ? float3(0,1,0):float3(1,0,0),normal));
    return tangent*x+cross(normal,tangent)*y+normal*z;
}
// Live pass: reconstruct reverse-Z depth in camera-relative world space.
struct FrameParameters {
    float4x4 inverse_view_projection;
    float4 camera;
    float4 sun;
    float4 controls;
    uint4 dimensions;
    float4 transport;
    float4 display;
};
static constant uint PHYSICAL_LIGHTING = 32768u;
struct Material {float4 tint;float4 surface;float4 uv01;float4 uv2;float4 optics;uint4 image;};
// Tier-2 Metal argument buffer. Static and posed attributes retain separate allocations.
struct GeometryBindings {
    device const packed_float3 *vertices[2];
    device const Material *materials[2];
    device const uint *texels[2];
    uint4 sizes; // static triangle count, static texel count, reserved
};
static_assert(sizeof(GeometryBindings)==64);
template<typename T> struct AttributeView {
    device const T *base;
    device const T *dynamic;
    uint count;
    device const T& operator[](uint index) const {return index<count?base[index]:dynamic[index-count];}
};
using VertexView=AttributeView<packed_float3>;
using MaterialView=AttributeView<Material>;
using TexelView=AttributeView<uint>;

struct SurfaceHit {float distance;uint primitive;float2 barycentric;bool found;};
struct Transport {float4 reflection;float4 indirect;};
static float3 linear_rgb(float3 value){return select(pow((value+.055f)/1.055f,float3(2.4f)),value/12.92f,value<=.04045f);}
static float3 srgb_rgb(float3 value){value=max(value,float3(0));return select(1.055f*pow(value,float3(1.f/2.4f))-.055f,value*12.92f,value<=.0031308f);}
static float4 texel_color(SurfaceHit hit,MaterialView materials,TexelView texels) {
    Material m=materials[hit.primitive];
    float2 uv=m.uv01.xy*(1-hit.barycentric.x-hit.barycentric.y)+m.uv01.zw*hit.barycentric.x+m.uv2.xy*hit.barycentric.y;
    uint2 coord=min(uint2(saturate(uv)*float2(m.image.yz)),m.image.yz-1);
    uint argb=texels[m.image.x+coord.y*m.image.y+coord.x];
    return float4(linear_rgb(float3((argb>>16)&255,(argb>>8)&255,argb&255)/255.f)*m.tint.xyz,float((argb>>24)&255)/255.f*m.tint.w);
}
// Closest hardware intersections with bounded alpha rejection; no screen-space lookup.
static SurfaceHit material_hit(ray r,instance_acceleration_structure scene,MaterialView materials,TexelView texels) {
    intersector<triangle_data,instancing> q;q.assume_geometry_type(geometry_type::triangle);q.force_opacity(forced_opacity::opaque);
    for(uint layer=0;layer<32;layer++){
        auto h=q.intersect(r,scene);
        if(h.type==intersection_type::none)return {-1,0,float2(0),false};
        SurfaceHit hit={h.distance,h.primitive_id+h.user_instance_id,h.triangle_barycentric_coord,true};
        Material m=materials[hit.primitive];
        if(!(m.image.w&1u)||texel_color(hit,materials,texels).w>=m.optics.y)return hit;
        r.min_distance=hit.distance+.0001f;if(r.min_distance>=r.max_distance)break;
    }
    return {-1,0,float2(0),false};
}
static float3 surface_normal(SurfaceHit hit,float3 direction,VertexView vertices) {
    uint b=hit.primitive*3;float3 n=normalize(cross(float3(vertices[b+1])-float3(vertices[b]),float3(vertices[b+2])-float3(vertices[b])));
    return dot(n,direction)>0?-n:n;
}
// Straight visibility rays transmit through dielectric boundaries. This omits caustic
// focusing; the surface color filter is an explicit thin-boundary approximation.
static float dielectric_fresnel(float cosine,float etaI,float etaT) {
    cosine=saturate(cosine);float eta=etaI/etaT;
    float sin2=eta*eta*(1-cosine*cosine);if(sin2>=1)return 1;
    float ct=sqrt(max(0.f,1-sin2));
    float rs=(etaI*cosine-etaT*ct)/max(etaI*cosine+etaT*ct,.000001f);
    float rp=(etaT*cosine-etaI*ct)/max(etaT*cosine+etaI*ct,.000001f);
    return saturate((rs*rs+rp*rp)*.5f);
}
static float3 geometric_normal(SurfaceHit hit,VertexView vertices) {
    uint b=hit.primitive*3;return normalize(cross(float3(vertices[b+1])-float3(vertices[b]),float3(vertices[b+2])-float3(vertices[b])));
}
static float3 boundary_filter(SurfaceHit hit,MaterialView materials,TexelView texels) {
    float4 color=texel_color(hit,materials,texels);
    Material m=materials[hit.primitive];
    return m.surface.w*(m.optics.w>0?float3(1):mix(float3(1),saturate(color.xyz),saturate(color.w)*.2f));
}
static float3 absorption_coefficient(SurfaceHit hit,MaterialView materials,TexelView texels){
    float4 color=texel_color(hit,materials,texels);
    return (1-saturate(color.xyz))*saturate(color.w)*materials[hit.primitive].optics.w;
}
static float3 ray_transmittance(ray r,instance_acceleration_structure scene,VertexView vertices,
                                MaterialView materials,TexelView texels) {
    float3 weight=1,medium=0;float previous=0;
    for(uint layer=0;layer<32;layer++){
        SurfaceHit h=material_hit(r,scene,materials,texels);if(!h.found)return weight*exp(-medium*(r.max_distance-previous));
        Material m=materials[h.primitive];if(m.surface.w<=0)return float3(0);
        float3 outward=geometric_normal(h,vertices);bool entering=dot(outward,r.direction)<0;
        // This visibility ray retains the exterior direction at both boundaries.
        // Using an internal-to-air angle here would invent TIR without refraction.
        float f=dielectric_fresnel(abs(dot(outward,r.direction)),1.f,m.optics.x);
        if(layer==0&&!entering)medium=absorption_coefficient(h,materials,texels);
        weight*=exp(-medium*(h.distance-previous))*boundary_filter(h,materials,texels)*(1-f);
        medium=entering?absorption_coefficient(h,materials,texels):float3(0);previous=h.distance;
        if(max(max(weight.x,weight.y),weight.z)<.0001f)return float3(0);
        r.min_distance=h.distance+.0001f;if(r.min_distance>=r.max_distance)return weight;
    }
    return float3(0); // Exhaustion is conservative, never a light leak.
}
struct AreaLight {float4 center,half_u,half_v,radiance;};
struct SampledLight {AreaLight light;float4 distribution;};
struct LightReceiver {float4 position,normal;};
// Importance-selected emitter and uniform surface-area sampling. Divide by the
// selected discrete probability and area density to preserve incident energy.
static float3 local_irradiance(float3 position,float3 normal,device const SampledLight *lights,uint count,
    instance_acceleration_structure scene,VertexView vertices,MaterialView materials,TexelView texels,float bias,thread uint &state){
    if(!count)return float3(0);
    float choice=random01(state);uint low=0,high=count;
    while(low<high){uint middle=(low+high)/2;if(choice<lights[middle].distribution.x)high=middle;else low=middle+1;}
    uint index=min(low,count-1);AreaLight l=lights[index].light;float probability=lights[index].distribution.y;
    float3 target=l.center.xyz+(2*random01(state)-1)*l.half_u.xyz+(2*random01(state)-1)*l.half_v.xyz;
    float3 delta=target-position;float d2=dot(delta,delta);if(d2<=bias*bias)return float3(0);
    float distance=sqrt(d2);float3 direction=delta/distance,crossed=cross(l.half_u.xyz,l.half_v.xyz);
    float area=4*length(crossed),receiverCos=max(0.f,dot(normal,direction));
    float lightCos=dot(normalize(crossed),-direction);lightCos=l.half_v.w>0?abs(lightCos):max(0.f,lightCos);
    if(receiverCos<=0||lightCos<=0)return float3(0);
    // Visibility is a finite segment; objects beyond the emitter cannot shadow it.
    // Keep the physical endpoint/geometry factor unbiased by the ray-origin offset.
    ray r;r.origin=position+normal*bias;delta=target-r.origin;distance=length(delta);
    if(distance<=bias)return float3(0);
    r.direction=delta/distance;r.min_distance=0;r.max_distance=distance-bias;
    return l.radiance.xyz*(area*receiverCos*lightCos/(d2*probability))*ray_transmittance(r,scene,vertices,materials,texels);
}
kernel void trace_local_lighting(instance_acceleration_structure scene [[buffer(0)]],constant GeometryBindings &geometry [[buffer(1)]],
    device const LightReceiver *receivers [[buffer(2)]],device float4 *output [[buffer(3)]],device const SampledLight *lights [[buffer(4)]],
    constant uint4 &settings [[buffer(5)]],constant float &bias [[buffer(6)]],uint i [[thread_position_in_grid]]){
    if(i>=settings.x)return;
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    uint state=(i+1)*747796405u+settings.z*2891336453u;float3 sum=0;
    for(uint sample=0;sample<settings.y;sample++)sum+=local_irradiance(receivers[i].position.xyz,receivers[i].normal.xyz,lights,settings.w,scene,vertices,materials,texels,bias,state);
    output[i]=float4(sum/float(settings.y),0);
}
kernel void trace_visibility(instance_acceleration_structure scene [[buffer(0)]],device const InputRay *inputs [[buffer(1)]],
    device float4 *output [[buffer(2)]],constant uint &count [[buffer(3)]],constant VisibilitySettings &settings [[buffer(4)]],
    constant GeometryBindings &geometry [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    if(i>=count)return;
    ray primary;primary.origin=inputs[i].origin.xyz;primary.direction=inputs[i].direction.xyz;primary.min_distance=inputs[i].origin.w;primary.max_distance=inputs[i].direction.w;
    SurfaceHit hit=material_hit(primary,scene,materials,texels);
    if(!hit.found){output[i]=float4(1,1,-1,0);return;}
    float3 normal=surface_normal(hit,primary.direction,vertices);
    float3 position=primary.origin+hit.distance*primary.direction+normal*settings.ray_bias;
    float ao=0,shadow=0;uint state=(i+1)*747796405u+settings.seed+2891336453u;
    for(uint sample=0;sample<settings.samples;sample++){
        float r=sqrt(random01(state)),phi=6.28318530718f*random01(state);
        ray ambient;ambient.origin=position;ambient.direction=around(normal,r*cos(phi),r*sin(phi),sqrt(max(0.f,1-r*r)));ambient.min_distance=0;ambient.max_distance=settings.ao_distance;
        ao+=dot(ray_transmittance(ambient,scene,vertices,materials,texels),float3(.2126f,.7152f,.0722f));
        float sunR=tan(settings.sun.w)*sqrt(random01(state));phi=6.28318530718f*random01(state);
        float3 direction=normalize(around(settings.sun.xyz,sunR*cos(phi),sunR*sin(phi),1));
        ray sunlight;sunlight.origin=position;sunlight.direction=direction;sunlight.min_distance=0;sunlight.max_distance=10000;
        shadow+=dot(normal,direction)>0?dot(ray_transmittance(sunlight,scene,vertices,materials,texels),float3(.2126f,.7152f,.0722f)):0.f;
    }
    output[i]=float4(ao/settings.samples,shadow/settings.samples,hit.distance,1);
}
static float3 sky_radiance(float3 direction,constant FrameParameters &p){
    return mix(float3(.035f,.045f,.065f),float3(.16f,.25f,.4f),saturate(direction.y))*max(p.sun.y,0.f);
}
static bool sampled_emitter(float3 point,device const SampledLight *lights,uint count){
    for(uint i=0;i<count;i++){
        AreaLight l=lights[i].light;float3 delta=point-l.center.xyz,u=l.half_u.xyz,v=l.half_v.xyz;
        float3 n=normalize(cross(u,v));
        if(abs(dot(delta,n))<.0002f&&abs(dot(delta,u))<=dot(u,u)+.0001f&&abs(dot(delta,v))<=dot(v,v)+.0001f)return true;
    }
    return false;
}
static float3 secondary_radiance(ray r,SurfaceHit h,instance_acceleration_structure scene,VertexView vertices,
                                MaterialView materials,TexelView texels,constant FrameParameters &p,device const SampledLight *lights,uint lightCount,thread uint &state,bool partitionEmission=false) {
    if(!h.found)return float3(0);
    Material m=materials[h.primitive];float3 albedo=texel_color(h,materials,texels).xyz;
    float3 n=surface_normal(h,r.direction,vertices),point=r.origin+r.direction*h.distance;
    float cosine=max(0.f,dot(n,p.sun.xyz));float3 visible=0;
    if(p.sun.y>0&&cosine>0){ray s;s.origin=point+n*p.controls.y;s.direction=p.sun.xyz;s.min_distance=0;s.max_distance=p.transport.w;
        visible=ray_transmittance(s,scene,vertices,materials,texels);}
    float3 emission=albedo*m.surface.z;
    if(partitionEmission&&lightCount&&m.surface.z>0&&sampled_emitter(point,lights,lightCount))emission=0;
    float3 irradiance=p.transport.z*cosine*visible;
    if(lightCount&&m.surface.y<1&&m.surface.w<1)irradiance+=local_irradiance(point,n,lights,lightCount,scene,vertices,materials,texels,p.controls.y,state);
    return emission+albedo*(1-m.surface.y)*(1-m.surface.w)*irradiance/3.14159265f;
}
// Resolve a dielectric chain while preserving the medium for the next diffuse segment.
// Nested/overlapping media still require a medium stack.
static float3 transmission_endpoint(thread ray &r,thread SurfaceHit &hit,thread float3 &medium,
    instance_acceleration_structure scene,VertexView vertices,MaterialView materials,TexelView texels,constant FrameParameters &p){
    float3 weight=1;
    for(uint layer=0;layer<16;layer++){
        if(!hit.found)return weight*exp(-medium*r.max_distance);
        weight*=exp(-medium*hit.distance);
        Material m=materials[hit.primitive];if(m.surface.w<=0)return weight;
        float3 outward=geometric_normal(hit,vertices);bool entering=dot(outward,r.direction)<0;float3 n=entering?outward:-outward;
        float etaI=entering?1.f:m.optics.x,etaT=entering?m.optics.x:1.f;
        float f=dielectric_fresnel(-dot(n,r.direction),etaI,etaT);
        float3 direction=refract(r.direction,n,etaI/etaT);
        if(dot(direction,direction)<.000001f)direction=reflect(r.direction,n);
        else{weight*=boundary_filter(hit,materials,texels)*(1-f);medium=entering?absorption_coefficient(hit,materials,texels):float3(0);}
        float remaining=r.max_distance-hit.distance;if(remaining<=0){hit.found=false;return float3(0);}
        r.origin+=r.direction*hit.distance+direction*p.controls.y;r.direction=normalize(direction);r.min_distance=0;r.max_distance=remaining;
        hit=material_hit(r,scene,materials,texels);
    }
    hit.found=false;return float3(0);
}
static float3 transmitted_radiance(ray r,SurfaceHit hit,instance_acceleration_structure scene,VertexView vertices,
    MaterialView materials,TexelView texels,constant FrameParameters &p,device const SampledLight *lights,uint lightCount,thread uint &state,float3 medium=float3(0)){
    float3 weight=transmission_endpoint(r,hit,medium,scene,vertices,materials,texels,p);
    return weight*(hit.found?secondary_radiance(r,hit,scene,vertices,materials,texels,p,lights,lightCount,state):sky_radiance(r.direction,p));
}
// The transmitted image has no baked ambient term: explicitly integrate indirect
// light at its opaque endpoint, including visible environment radiance on a miss.
static float3 refracted_radiance(ray r,SurfaceHit hit,float3 medium,instance_acceleration_structure scene,VertexView vertices,
    MaterialView materials,TexelView texels,constant FrameParameters &p,thread uint &state,device const SampledLight *lights,uint lightCount){
    float3 weight=transmission_endpoint(r,hit,medium,scene,vertices,materials,texels,p);
    if(!hit.found)return weight*sky_radiance(r.direction,p);
    float3 radiance=weight*secondary_radiance(r,hit,scene,vertices,materials,texels,p,lights,lightCount,state);
    if(p.transport.y<=0||(p.dimensions.w&4u))return radiance;
    uint bounces=clamp((p.dimensions.w>>8)&7u,1u,4u);
    float3 indirect=0;
    for(uint bounce=0;bounce<bounces;bounce++){
        Material m=materials[hit.primitive];weight*=texel_color(hit,materials,texels).xyz*(1-m.surface.y)*(1-m.surface.w);
        if(max(max(weight.x,weight.y),weight.z)<.0001f)break;
        float3 normal=surface_normal(hit,r.direction,vertices);
        r.origin+=r.direction*hit.distance+normal*p.controls.y;
        float radius=sqrt(random01(state)),phi=6.2831853f*random01(state);
        r.direction=around(normal,radius*cos(phi),radius*sin(phi),sqrt(max(0.f,1-radius*radius)));r.min_distance=0;r.max_distance=p.transport.w;
        hit=material_hit(r,scene,materials,texels);
        bool dielectricSegment=hit.found&&materials[hit.primitive].surface.w>0;
        weight*=transmission_endpoint(r,hit,medium,scene,vertices,materials,texels,p);
        if(!hit.found){indirect+=weight*sky_radiance(r.direction,p);break;}
        indirect+=weight*secondary_radiance(r,hit,scene,vertices,materials,texels,p,lights,lightCount,state,!dielectricSegment);
    }
    return radiance+indirect*p.transport.y;
}
static float geometry_g1(float cosine,float alpha2){return 2*cosine/max(cosine+sqrt(alpha2+(1-alpha2)*cosine*cosine),.00001f);}
// Same isotropic GGX distribution and separable Smith masking as the reflection sampler.
struct SpecularEvaluation {float3 brdf;float pdf;};
static SpecularEvaluation specular_evaluate(Material m,float3 albedo,float3 n,float3 view,float3 direction){
    float noV=dot(n,view),noL=dot(n,direction);if(noV<=0||noL<=0)return {float3(0),0};
    float3 sum=view+direction;if(dot(sum,sum)<1e-10f)return {float3(0),0};float3 h=normalize(sum);
    float noH=max(0.f,dot(n,h)),voH=max(0.f,dot(view,h));if(noH<=0||voH<=0)return {float3(0),0};
    float alpha=max(.001f,m.surface.x*m.surface.x),alpha2=alpha*alpha;
    float term=noH*noH*(alpha2-1)+1,distribution=alpha2/(3.14159265f*term*term);
    float dielectric=pow((m.optics.x-1)/(m.optics.x+1),2.f);
    float3 f0=mix(float3(dielectric),albedo,m.surface.y)*m.optics.z;
    float3 fresnel=f0+(1-f0)*pow(1-voH,5.f);
    return {fresnel*(distribution*geometry_g1(noV,alpha2)*geometry_g1(noL,alpha2)/(4*noV*noL)),distribution*noH/(4*voH)};
}
static float power_weight(float sampled,float alternate){
    if(sampled<=0)return 0;float ratio=alternate/sampled;return 1/(1+ratio*ratio);
}
// Rectangle emitters collected from non-overlapping baked quads use the same
// directional measure as the GGX reflection sample. Back faces have zero emission.
static float emitter_pdf(float3 origin,float3 target,float3 direction,device const SampledLight *lights,uint count,thread bool &represented){
    float pdf=0;represented=false;
    for(uint i=0;i<count;i++){
        AreaLight l=lights[i].light;float3 u=l.half_u.xyz,v=l.half_v.xyz,delta=target-l.center.xyz;
        if(any(abs(delta)>abs(u)+abs(v)+.0002f))continue;
        float3 crossed=cross(u,v),normal=normalize(crossed);
        if(abs(dot(delta,normal))>.0002f||abs(dot(delta,u))>dot(u,u)+.0001f||abs(dot(delta,v))>dot(v,v)+.0001f)continue;
        represented=true;float cosine=dot(normal,-direction);cosine=l.half_v.w>0?abs(cosine):max(0.f,cosine);
        if(cosine>0){float3 travel=target-origin;pdf+=lights[i].distribution.y*dot(travel,travel)/(4*length(crossed)*cosine);}
    }
    return pdf;
}
struct EmissionSample {float3 radiance;bool represented;};
static EmissionSample sampled_emission(float3 target,float3 normal,float3 fallback,
    instance_acceleration_structure scene,MaterialView materials,TexelView texels){
    // A tiny opaque query identifies the selected emitter texel, including alpha
    // holes. Analytical lights without emissive geometry retain their input radiance.
    ray probe;probe.origin=target+normal*.002f;probe.direction=-normal;probe.min_distance=0;probe.max_distance=.004f;
    intersector<triangle_data,instancing> query;query.assume_geometry_type(geometry_type::triangle);query.force_opacity(forced_opacity::opaque);
    auto h=query.intersect(probe,scene);
    if(h.type!=intersection_type::none&&abs(h.distance-.002f)<.0002f){
        SurfaceHit hit={h.distance,h.primitive_id+h.user_instance_id,h.triangle_barycentric_coord,true};Material m=materials[hit.primitive];
        if(m.surface.z>0&&m.surface.w<=0){float4 color=texel_color(hit,materials,texels);
            return {((m.image.w&1u)&&color.w<m.optics.y)?float3(0):color.xyz*m.surface.z,true};}
    }
    return {fallback,false};
}
static float3 local_specular(float3 position,float3 normal,float3 view,Material m,float3 albedo,
    device const SampledLight *lights,uint count,instance_acceleration_structure scene,VertexView vertices,MaterialView materials,TexelView texels,float bias,thread uint &state){
    if(!count)return float3(0);
    float choice=random01(state);uint low=0,high=count;
    while(low<high){uint middle=(low+high)/2;if(choice<lights[middle].distribution.x)high=middle;else low=middle+1;}
    uint index=min(low,count-1);AreaLight l=lights[index].light;
    float3 target=l.center.xyz+(2*random01(state)-1)*l.half_u.xyz+(2*random01(state)-1)*l.half_v.xyz;
    float3 travel=target-position;float d2=dot(travel,travel);if(d2<=bias*bias)return float3(0);
    float3 direction=normalize(travel),crossed=cross(l.half_u.xyz,l.half_v.xyz),emitterNormal=normalize(crossed);
    float cosine=dot(emitterNormal,-direction);cosine=l.half_v.w>0?abs(cosine):max(0.f,cosine);
    float noL=dot(normal,direction);if(cosine<=0||noL<=0)return float3(0);
    auto specular=specular_evaluate(m,albedo,normal,view,direction);if(specular.pdf<=0)return float3(0);
    auto emission=sampled_emission(target,emitterNormal,l.radiance.xyz,scene,materials,texels);
    if(!any(emission.radiance>0))return float3(0);
    float pdf=lights[index].distribution.y*d2/(4*length(crossed)*cosine);
    float weight=emission.represented?power_weight(pdf,specular.pdf):1.f;
    ray visibility;visibility.origin=position+normal*bias;travel=target-visibility.origin;float distance=length(travel);
    if(distance<=bias)return float3(0);visibility.direction=travel/distance;visibility.min_distance=0;visibility.max_distance=distance-bias;
    // A refractive segment changes the path measure. Let the existing BSDF /
    // transmission strategy own it rather than combining a straight visibility
    // approximation with a bent path. Alpha-tested holes still pass material_hit.
    if(material_hit(visibility,scene,materials,texels).found)return float3(0);
    return emission.radiance*specular.brdf*(noL*weight/pdf);
}
static float3 sun_specular(float3 position,float3 normal,float3 view,Material m,float3 albedo,
    instance_acceleration_structure scene,VertexView vertices,MaterialView materials,TexelView texels,constant FrameParameters &p,thread uint &state){
    if(p.sun.y<=0||p.transport.z<=0)return float3(0);
    float cosineRadius=cos(p.sun.w),cosine=1-random01(state)*(1-cosineRadius),phi=6.2831853f*random01(state);
    float sine=sqrt(max(0.f,1-cosine*cosine));float3 direction=around(p.sun.xyz,sine*cos(phi),sine*sin(phi),cosine);
    auto specular=specular_evaluate(m,albedo,normal,view,direction);if(specular.pdf<=0)return float3(0);
    ray visibility;visibility.origin=position+normal*p.controls.y;visibility.direction=direction;visibility.min_distance=0;visibility.max_distance=p.transport.w;
    float3 transmittance=ray_transmittance(visibility,scene,vertices,materials,texels);
    // Constant disk radiance normalized to p.transport.z normal-plane irradiance.
    // The procedural sky contains no sun disk, so there is no competing sky sample.
    return specular.brdf*(p.transport.z*max(0.f,dot(normal,direction))*2/(1+cosineRadius))*mix(float3(1),transmittance,p.controls.w);
}
static Transport transport_sample(ray primary,SurfaceHit hit,instance_acceleration_structure scene,VertexView vertices,
                                  MaterialView materials,TexelView texels,constant FrameParameters &p,thread uint &state,device const SampledLight *lights,uint lightCount) {
    Transport out={float4(0),float4(0)};if(!hit.found)return out;out.indirect.w=1;
    Material m=materials[hit.primitive];float3 albedo=texel_color(hit,materials,texels).xyz;
    float3 n=surface_normal(hit,primary.direction,vertices),view=normalize(-primary.direction);
    float3 point=primary.origin+primary.direction*hit.distance+n*p.controls.y;
    float noV=max(dot(n,view),.0001f);
    bool directSpecular=(p.dimensions.w&PHYSICAL_LIGHTING)&&!(p.dimensions.w&65536u)&&m.surface.w<=0;
    if(p.transport.x>0){
        float alpha=max(.001f,m.surface.x*m.surface.x),alpha2=alpha*alpha;
        float u=random01(state),phi=6.2831853f*random01(state),cosTheta=sqrt((1-u)/(1+(alpha2-1)*u));
        float sinTheta=sqrt(max(0.f,1-cosTheta*cosTheta));
        float3 h=around(n,sinTheta*cos(phi),sinTheta*sin(phi),cosTheta);
        float voH=dot(view,h);float3 direction=reflect(-view,h);float noL=dot(n,direction);
        if(voH>0&&noL>0){
            float dielectric=pow((m.optics.x-1)/(m.optics.x+1),2.f);
            float3 f0=mix(float3(dielectric),albedo,m.surface.y)*m.optics.z;
            float3 fresnel=f0+(1-f0)*pow(1-saturate(voH),5.f);
            if(m.surface.w>0){bool entering=dot(geometric_normal(hit,vertices),primary.direction)<0;
                fresnel=float3(dielectric_fresnel(voH,entering?1.f:m.optics.x,entering?m.optics.x:1.f));}
            float3 weight=fresnel*(geometry_g1(noV,alpha2)*geometry_g1(noL,alpha2)*voH/max(noV*cosTheta,.00001f));
            ray r;r.origin=point;r.direction=direction;r.min_distance=0;r.max_distance=p.transport.w;
            SurfaceHit reflected=material_hit(r,scene,materials,texels);
            float3 li=transmitted_radiance(r,reflected,scene,vertices,materials,texels,p,lights,lightCount,state);
            if(directSpecular&&lightCount&&reflected.found&&materials[reflected.primitive].surface.w<=0&&materials[reflected.primitive].surface.z>0){
                bool represented=false;float3 origin=primary.origin+primary.direction*hit.distance;
                float pdf=emitter_pdf(origin,r.origin+r.direction*reflected.distance,r.direction,lights,lightCount,represented);
                if(represented){auto evaluation=specular_evaluate(m,albedo,n,view,direction);
                    float3 emission=texel_color(reflected,materials,texels).xyz*materials[reflected.primitive].surface.z;
                    li=max(float3(0),li-emission)+emission*(pdf>0?power_weight(evaluation.pdf,pdf):0.f);}
            }
            out.reflection=float4(max(float3(0),li*weight),saturate(dot(weight,float3(.2126f,.7152f,.0722f))));
        }
    }
    if(p.transport.x>0&&directSpecular){
        float3 origin=primary.origin+primary.direction*hit.distance;
        out.reflection.xyz+=local_specular(origin,n,view,m,albedo,lights,lightCount,scene,vertices,materials,texels,p.controls.y,state);
        out.reflection.xyz+=sun_specular(origin,n,view,m,albedo,scene,vertices,materials,texels,p,state);
    }
    if(p.transport.x>0 && m.surface.w>0){
        float3 outward=geometric_normal(hit,vertices);bool entering=dot(outward,primary.direction)<0;
        float etaI=entering?1.f:m.optics.x,etaT=entering?m.optics.x:1.f;
        float f=dielectric_fresnel(noV,etaI,etaT);float3 direction=refract(primary.direction,n,etaI/etaT);
        if(dot(direction,direction)>.000001f){
            ray r;r.origin=primary.origin+primary.direction*hit.distance+direction*p.controls.y;r.direction=normalize(direction);r.min_distance=0;r.max_distance=p.transport.w;
            float3 weight=boundary_filter(hit,materials,texels)*(1-f);
            out.reflection.xyz+=weight*refracted_radiance(r,material_hit(r,scene,materials,texels),entering?absorption_coefficient(hit,materials,texels):float3(0),scene,vertices,materials,texels,p,state,lights,lightCount);
            out.reflection.w=saturate(out.reflection.w+(1-f)*m.surface.w);
        }
    }
    if(p.transport.y>0 && m.surface.y<1 && m.surface.w<1){
        float radius=sqrt(random01(state)),phi=6.2831853f*random01(state);
        ray r;r.origin=point;r.direction=around(n,radius*cos(phi),radius*sin(phi),sqrt(max(0.f,1-radius*radius)));r.min_distance=0;r.max_distance=p.transport.w;
        // Finite diffuse path tier. A zero flag retains the original one-bounce default.
        uint bounces=clamp((p.dimensions.w>>8)&7u,1u,4u);
        float3 throughput=albedo*(1-m.surface.y)*(1-m.surface.w);
        for(uint bounceIndex=0;bounceIndex<bounces;bounceIndex++){
            SurfaceHit bounce=material_hit(r,scene,materials,texels);
            if(!bounce.found){if(p.dimensions.w&PHYSICAL_LIGHTING)out.indirect.xyz+=throughput*sky_radiance(r.direction,p);break;}
            // Each diffuse vertex samples local light explicitly. A straight diffuse
            // segment that reaches that same emitter must not add its emission again.
            // Dielectric segments retain emission because their refracted paths differ.
            bool dielectricSegment=materials[bounce.primitive].surface.w>0;float3 medium=0;
            throughput*=transmission_endpoint(r,bounce,medium,scene,vertices,materials,texels,p);
            if(!bounce.found){out.indirect.xyz+=throughput*sky_radiance(r.direction,p);break;}
            out.indirect.xyz+=throughput*secondary_radiance(r,bounce,scene,vertices,materials,texels,p,lights,lightCount,state,!dielectricSegment);
            if(bounceIndex+1>=bounces)break;
            Material next=materials[bounce.primitive];throughput*=texel_color(bounce,materials,texels).xyz*(1-next.surface.y)*(1-next.surface.w);
            if(max(max(throughput.x,throughput.y),throughput.z)<.0001f)break;
            float3 bounceNormal=surface_normal(bounce,r.direction,vertices);
            r.origin+=r.direction*bounce.distance+bounceNormal*p.controls.y;
            radius=sqrt(random01(state));phi=6.2831853f*random01(state);
            r.direction=around(bounceNormal,radius*cos(phi),radius*sin(phi),sqrt(max(0.f,1-radius*radius)));r.max_distance=p.transport.w;
        }
    }
    return out;
}
kernel void trace_transport(instance_acceleration_structure scene [[buffer(0)]],constant GeometryBindings &geometry [[buffer(1)]],
                            device const InputRay *rays [[buffer(4)]],device Transport *output [[buffer(5)]],constant FrameParameters &p [[buffer(6)]],
                            constant uint &count [[buffer(7)]],constant uint &samples [[buffer(8)]],device const SampledLight *lights [[buffer(9)]],constant uint &lightCount [[buffer(10)]],uint i [[thread_position_in_grid]]) {
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    if(i>=count)return;
    ray r;r.origin=rays[i].origin.xyz;r.min_distance=rays[i].origin.w;r.direction=rays[i].direction.xyz;r.max_distance=rays[i].direction.w;
    SurfaceHit hit=material_hit(r,scene,materials,texels);Transport sum={float4(0),float4(0)};
    uint state=(i+1)*747796405u+p.dimensions.z*2891336453u;
    for(uint s=0;s<samples;s++){auto value=transport_sample(r,hit,scene,vertices,materials,texels,p,state,lights,lightCount);sum.reflection+=value.reflection;sum.indirect+=value.indirect;}
    output[i]={sum.reflection/float(samples),sum.indirect/float(samples)};
}

static float3 frame_position(float2 uv,float depth,constant FrameParameters &p) {
    // Metallum's offscreen target is vertically inverted, then flipped at presentation.
    float4 point=p.inverse_view_projection*float4(uv.x*2-1,uv.y*2-1,depth,1);
    return point.xyz/point.w;
}
// Variance of the per-frame sample mean, separate from variation caused by motion.
static float3 sample_mean_variance(float3 sum,float3 squares,uint count){
    return count>1?max(float3(0),(squares-sum*sum/float(count))/(float(count)*float(count-1))):float3(0);
}
struct FrameSample {float4 visibility,reflection,indirect,normal,position,local,reflectionVariance,indirectVariance,localVariance;};
static FrameSample shade_frame_pixel(uint2 fullPixel,uint2 fullSize,float z,uint samples,instance_acceleration_structure scene,
    VertexView vertices,MaterialView materials,TexelView texels,constant FrameParameters &p,device const SampledLight *lights,uint lightCount){
    FrameSample result={};result.visibility=float4(1,1,0,0);
    float2 uv=(float2(fullPixel)+.5f)/float2(fullSize);
    float3 relative=frame_position(uv,z>0?z:1.f,p);float distance=z>0?length(relative):0;
    ray primary;primary.origin=p.camera.xyz;primary.direction=normalize(relative);
    primary.min_distance=.01f;primary.max_distance=z>0?distance+.2f:p.transport.w;
    intersector<triangle_data,instancing> query;query.assume_geometry_type(geometry_type::triangle);query.force_opacity(forced_opacity::opaque);
    SurfaceHit hit=material_hit(primary,scene,materials,texels);
    bool transparent=hit.found&&materials[hit.primitive].surface.w>0;
    if(!hit.found || (!transparent&&abs(hit.distance-distance)>max(.06f,distance*.002f))){
        result.visibility=float4(1,1,distance,0);return result;
    }
    uint base=hit.primitive*3;
    float3 normal=normalize(cross(float3(vertices[base+1])-float3(vertices[base]),float3(vertices[base+2])-float3(vertices[base])));
    if(dot(normal,primary.direction)>0)normal=-normal;
    result.normal=float4(normal,materials[hit.primitive].surface.x);result.position=float4(primary.origin+primary.direction*hit.distance,float(hit.primitive+1));
    float3 position=primary.origin+primary.direction*hit.distance+normal*p.controls.y;
    float edge=min(min(min(position.x,position.y),position.z),min(min(p.camera.w-position.x,p.camera.w-position.y),p.camera.w-position.z));
    // Section collection spans the complete dimension height; fade only at horizontal radius boundaries.
    if(p.dimensions.w&2048u)edge=min(min(position.x,position.z),min(p.camera.w-position.x,p.camera.w-position.z));
    float confidence=saturate(edge/2);
    intersector<triangle_data,instancing> visibility;visibility.assume_geometry_type(geometry_type::triangle);visibility.force_opacity(forced_opacity::opaque);visibility.accept_any_intersection(true);
    uint randomState=(fullPixel.y*fullSize.x+fullPixel.x+1)*747796405u+p.dimensions.z*2891336453u;
    float ambient=0,sun=0;float3 sunRadiance=0,sunSquares=0;
    bool physical=(p.dimensions.w&PHYSICAL_LIGHTING)!=0;
    Material primaryMaterial=materials[hit.primitive];
    float3 primaryAlbedo=texel_color(hit,materials,texels).xyz;
    float3 primaryBrdf=primaryAlbedo*(1-primaryMaterial.surface.y)*(1-primaryMaterial.surface.w)/3.14159265f;
    // Transparent primary surfaces compose reflected/refracted radiance; their
    // raster AO/sun factors are unity, so these visibility queries have no use.
    if(!transparent)for(uint sample=0;sample<samples;sample++){
        float r=sqrt(random01(randomState)),phi=6.2831853f*random01(randomState);
        ray a;a.origin=position;a.direction=around(normal,r*cos(phi),r*sin(phi),sqrt(max(0.f,1-r*r)));a.min_distance=0;a.max_distance=p.controls.x;
        ambient+=dot(ray_transmittance(a,scene,vertices,materials,texels),float3(.2126f,.7152f,.0722f));
        if(p.sun.y<=0 || dot(normal,p.sun.xyz)<=0){sun+=1;continue;}
        r=tan(p.sun.w)*sqrt(random01(randomState));phi=6.2831853f*random01(randomState);
        ray s;s.origin=position;s.direction=normalize(around(p.sun.xyz,r*cos(phi),r*sin(phi),1));s.min_distance=0;s.max_distance=1000;
        float3 sunTransmission=ray_transmittance(s,scene,vertices,materials,texels);
        sun+=dot(sunTransmission,float3(.2126f,.7152f,.0722f));
        if(physical){
            float3 radiance=primaryBrdf*p.transport.z*max(0.f,dot(normal,s.direction))*mix(float3(1),sunTransmission,p.controls.w);
            sunRadiance+=radiance;sunSquares+=radiance*radiance;
        }
    }
    Transport total={float4(0),float4(0)};float3 reflectionSquares=0,indirectSquares=0;
    for(uint sample=0;sample<samples;sample++){
        auto value=transport_sample(primary,hit,scene,vertices,materials,texels,p,randomState,lights,lightCount);
        total.reflection+=value.reflection;total.indirect+=value.indirect;
        reflectionSquares+=value.reflection.xyz*value.reflection.xyz;indirectSquares+=value.indirect.xyz*value.indirect.xyz;
    }
    result.reflection=total.reflection/float(samples);result.indirect=total.indirect/float(samples);
    result.reflectionVariance=float4(sample_mean_variance(total.reflection.xyz,reflectionSquares,samples),0);
    result.indirectVariance=float4(sample_mean_variance(total.indirect.xyz,indirectSquares,samples),0);
    if(!transparent&&lightCount&&materials[hit.primitive].surface.y<1){
        Material m=materials[hit.primitive];float3 radiance=0,squares=0;
        float3 brdf=texel_color(hit,materials,texels).xyz*(1-m.surface.y)*(1-m.surface.w)/3.14159265f;
        for(uint sample=0;sample<samples;sample++){
            float3 value=brdf*local_irradiance(result.position.xyz,normal,lights,lightCount,scene,vertices,materials,texels,p.controls.y,randomState);
            radiance+=value;squares+=value*value;
        }
        result.local=float4(radiance/float(samples),0);
        result.localVariance=float4(sample_mean_variance(radiance,squares,samples),0);
    }
    if(physical&&!transparent){
        // Primary emission and direct illumination replace baked surface light.
        // Traced diffuse paths already integrate occlusion; do not darken them again with AO.
        result.local.xyz+=sunRadiance/float(samples)+primaryAlbedo*primaryMaterial.surface.z;
        result.localVariance.xyz+=sample_mean_variance(sunRadiance,sunSquares,samples);
    }
    result.visibility=float4(transparent?1.f:ambient/float(samples),transparent?1.f:sun/float(samples),distance,confidence);return result;
}
kernel void frame_visibility(instance_acceleration_structure scene [[buffer(0)]],constant GeometryBindings &geometry [[buffer(1)]],
    constant FrameParameters &p [[buffer(2)]],device const SampledLight *lights [[buffer(3)]],constant uint &lightCount [[buffer(4)]],depth2d<float,access::read> depth [[texture(0)]],texture2d<float,access::write> visibility [[texture(1)]],
    texture2d<float,access::write> reflections [[texture(2)]],texture2d<float,access::write> indirect [[texture(3)]],
    texture2d<float,access::write> normals [[texture(4)]],texture2d<float,access::write> positions [[texture(5)]],texture2d<float,access::write> local [[texture(6)]],
    texture2d<float,access::write> reflectionVariance [[texture(7)]],texture2d<float,access::write> indirectVariance [[texture(8)]],texture2d<float,access::write> localVariance [[texture(9)]],uint2 pixel [[thread_position_in_grid]]){
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    if(any(pixel>=p.dimensions.xy))return;
    uint2 size=uint2(depth.get_width(),depth.get_height()),fullPixel=min(pixel*2+1,size-1);
    uint samples=(p.dimensions.w>>12)&7u;
    if(!samples)samples=(p.dimensions.w&16u)&&!(p.dimensions.w&64u)?1u:4u;
    auto sample=shade_frame_pixel(fullPixel,size,depth.read(fullPixel),samples,scene,vertices,materials,texels,p,lights,lightCount);
    visibility.write(sample.visibility,pixel);reflections.write(sample.reflection,pixel);indirect.write(sample.indirect,pixel);local.write(sample.local,pixel);
    reflectionVariance.write(sample.reflectionVariance,pixel);indirectVariance.write(sample.indirectVariance,pixel);localVariance.write(sample.localVariance,pixel);
    normals.write(sample.normal,pixel);positions.write(sample.position,pixel);
}
// Re-evaluate depth discontinuities at the output pixel. This repairs coverage that
// cannot be reconstructed from the half-resolution samples (thin glass frames/sky).
kernel void refine_frame_edges(instance_acceleration_structure scene [[buffer(0)]],constant GeometryBindings &geometry [[buffer(1)]],
    constant FrameParameters &p [[buffer(2)]],device const SampledLight *lights [[buffer(3)]],constant uint &lightCount [[buffer(4)]],depth2d<float,access::read> depth [[texture(0)]],texture2d<float,access::write> visibility [[texture(1)]],
    texture2d<float,access::write> reflections [[texture(2)]],texture2d<float,access::write> indirect [[texture(3)]],texture2d<float,access::write> local [[texture(4)]],uint2 pixel [[thread_position_in_grid]]){
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    uint2 size=uint2(depth.get_width(),depth.get_height());if(any(pixel>=size))return;
    visibility.write(float4(1,1,0,-1),pixel);if(p.dimensions.w&8u)return;
    float z=depth.read(pixel);float2 uv=(float2(pixel)+.5f)/float2(size);
    float distance=z>0?length(frame_position(uv,z,p)):0;bool edge=false;
    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
        uint2 neighbor=uint2(clamp(int2(pixel)+int2(x,y),int2(0),int2(size)-1));float nz=depth.read(neighbor);
        if((z>0)!=(nz>0)){edge=true;continue;}
        if(nz<=0)continue;
        float nd=length(frame_position((float2(neighbor)+.5f)/float2(size),nz,p));
        if(abs(nd-distance)>max(.08f,distance*.004f))edge=true;
    }
    if(!edge)return;
    uint samples=(p.dimensions.w>>12)&7u;
    samples=samples?2u*samples:((p.dimensions.w&16u)&&!(p.dimensions.w&64u)?2u:8u);
    auto sample=shade_frame_pixel(pixel,size,z,samples,scene,vertices,materials,texels,p,lights,lightCount);
    visibility.write(sample.visibility,pixel);reflections.write(sample.reflection,pixel);indirect.write(sample.indirect,pixel);local.write(sample.local,pixel);
}
// Static-scene camera motion. Moving entities need their own geometry/motion stream.
struct TemporalParameters {FrameParameters current;float4x4 previous_view_projection;float4 previous_camera;uint4 history;uint4 dynamic;};
struct GuideSurface {float3 albedo,normal;float roughness;};
static GuideSurface guide_endpoint(ray r,SurfaceHit hit,float3 medium,instance_acceleration_structure scene,
    VertexView vertices,MaterialView materials,TexelView texels,constant FrameParameters &p){
    float3 weight=transmission_endpoint(r,hit,medium,scene,vertices,materials,texels,p);
    if(!hit.found)return {weight*sky_radiance(r.direction,p),-r.direction,1};
    return {weight*texel_color(hit,materials,texels).xyz,surface_normal(hit,r.direction,vertices),materials[hit.primitive].surface.x};
}
// Noise-free material guides at the actual output pixel. Unrepresented geometry
// and sky are explicitly bypassed; they must not acquire false static-scene motion.
kernel void metalfx_guides(instance_acceleration_structure scene [[buffer(0)]],constant GeometryBindings &geometry [[buffer(1)]],
    constant TemporalParameters &t [[buffer(2)]],constant float4x4 &viewProjection [[buffer(5)]],
    depth2d<float,access::read> rasterDepth [[texture(0)]],texture2d<float,access::write> depth [[texture(1)]],
    texture2d<float,access::write> motion [[texture(2)]],texture2d<float,access::write> diffuse [[texture(3)]],
    texture2d<float,access::write> specular [[texture(4)]],texture2d<float,access::write> normal [[texture(5)]],
    texture2d<float,access::write> roughness [[texture(6)]],texture2d<float,access::write> mask [[texture(7)]],
    texture2d<float,access::write> reactive [[texture(8)]],texture2d<float,access::read> historyRejection [[texture(9)]],uint2 pixel [[thread_position_in_grid]]) {
    VertexView vertices{geometry.vertices[0],geometry.vertices[1],geometry.sizes.x*3};
    MaterialView materials{geometry.materials[0],geometry.materials[1],geometry.sizes.x};
    TexelView texels{geometry.texels[0],geometry.texels[1],geometry.sizes.y};
    uint2 size=uint2(rasterDepth.get_width(),rasterDepth.get_height());if(any(pixel>=size))return;
    constant FrameParameters &p=t.current;float2 uv=(float2(pixel)+.5f)/float2(size);float z=rasterDepth.read(pixel);
    float3 relative=frame_position(uv,z>0?z:1.f,p);float distance=z>0?length(relative):0;
    ray primary;primary.origin=p.camera.xyz;primary.direction=normalize(relative);primary.min_distance=.01f;
    primary.max_distance=z>0?distance+.2f:p.transport.w;
    auto hit=material_hit(primary,scene,materials,texels);
    bool accepted=hit.found&&(materials[hit.primitive].surface.w>0||abs(hit.distance-distance)<=max(.06f,distance*.002f));
    if(z>0&&hit.found&&hit.distance>distance+max(.06f,distance*.002f))accepted=false;
    float3 n=float3(0,1,0),kd=0,ks=0;float r=1;float2 velocity=0;float reject=1;
    if(accepted){
        auto m=materials[hit.primitive];n=surface_normal(hit,primary.direction,vertices);r=m.surface.x;
        float3 albedo=texel_color(hit,materials,texels).xyz;
        float cosine=saturate(-dot(n,primary.direction));
        float f=dielectric_fresnel(cosine,1.f,m.optics.x)*m.optics.z;
        ks=mix(float3(f),albedo+(1-albedo)*pow(1-cosine,5.f),m.surface.y);
        kd=albedo*(1-m.surface.y)*(1-m.surface.w)*(1-saturate(ks));
        float3 point=primary.origin+primary.direction*hit.distance;
        // Noise-free primary-surface replacement: expose the geometry seen in a
        // smooth reflection/transmission to the denoiser, not a featureless pane.
        if(p.transport.x>0&&m.surface.x<.25f&&!(p.dimensions.w&32u)){
            float3 interfaceNormal=n;
            ray reflected;reflected.origin=point+interfaceNormal*p.controls.y;reflected.direction=reflect(primary.direction,interfaceNormal);
            reflected.min_distance=0;reflected.max_distance=p.transport.w;
            auto reflectedGuide=guide_endpoint(reflected,material_hit(reflected,scene,materials,texels),float3(0),scene,vertices,materials,texels,p);
            if(m.surface.w>0){
                bool entering=dot(geometric_normal(hit,vertices),primary.direction)<0;
                float etaI=entering?1.f:m.optics.x,etaT=entering?m.optics.x:1.f;
                float fresnel=dielectric_fresnel(cosine,etaI,etaT);float3 direction=refract(primary.direction,interfaceNormal,etaI/etaT);
                GuideSurface transmittedGuide={float3(0),interfaceNormal,m.surface.x};
                if(dot(direction,direction)>.000001f){
                    ray transmitted;transmitted.origin=point+direction*p.controls.y;transmitted.direction=normalize(direction);transmitted.min_distance=0;transmitted.max_distance=p.transport.w;
                    transmittedGuide=guide_endpoint(transmitted,material_hit(transmitted,scene,materials,texels),entering?absorption_coefficient(hit,materials,texels):float3(0),scene,vertices,materials,texels,p);
                    transmittedGuide.albedo*=boundary_filter(hit,materials,texels);
                }
                kd=mix(transmittedGuide.albedo,reflectedGuide.albedo,fresnel);
                n=mix(transmittedGuide.normal,reflectedGuide.normal,fresnel);
                r=mix(transmittedGuide.roughness,reflectedGuide.roughness,fresnel);
            }else if(m.surface.y>.5f){kd=reflectedGuide.albedo*ks;n=reflectedGuide.normal;r=max(m.surface.x,reflectedGuide.roughness);}
            n=dot(n,n)>.0001f?normalize(n):interfaceNormal;
        }
        // Project the interface rather than the opaque depth behind water/glass.
        float4 currentClip=viewProjection*float4(point-p.camera.xyz,1);
        z=currentClip.z/currentClip.w;
        if(t.history.x){
            float4 clip=t.previous_view_projection*float4(point-t.previous_camera.xyz,1);
            if(clip.w>0){
                float2 oldUV=clip.xy/clip.w*.5f+.5f;velocity=(oldUV-uv)*float2(size);
                if(all(oldUV>=0)&&all(oldUV<=1))reject=0;
                // The static interface cannot describe all motion of its reflected image.
                if(m.surface.w>0||r<.15f)reject=max(reject,saturate(length(velocity)/8.f));
            }
        }
    }
    if(accepted&&(p.dimensions.w&128u)) {
        // Dilate half-resolution rejection to cover reconstruction footprints.
        // Changed posed surfaces have no object motion vectors yet: reject their
        // history directly, retaining it on unaffected static receivers instead.
        if(t.dynamic.x&&hit.primitive>=t.dynamic.y)reject=1;
        int2 center=int2(pixel/2);
        for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
            uint2 q=uint2(clamp(center+int2(x,y),int2(0),int2(p.dimensions.xy)-1));
            reject=max(reject,historyRejection.read(q).x);
        }
    }
    depth.write(float4(z),pixel);motion.write(float4(velocity,0,0),pixel);
    diffuse.write(float4(kd,1),pixel);specular.write(float4(ks,1),pixel);normal.write(float4(n,0),pixel);
    roughness.write(float4(r),pixel);mask.write(float4(accepted?0.f:1.f),pixel);reactive.write(float4(reject),pixel);
}
// Rectify history using current surface samples, without averaging their colors
// into the output. The finite interval also clears stale secondary-light history
// after an entity stops or disappears. This does not replace entity motion vectors.
static float4 rectify_history(float4 old,float4 minimum,float4 maximum,float4 sum,float4 squares,float taps){
    float4 mean=sum/taps,sigma=sqrt(max(float4(0),squares/taps-mean*mean));
    float4 low=max(minimum,mean-2*sigma),high=min(maximum,mean+2*sigma);
    return clamp(old,low,high);
}
static float4 history_innovation(float4 old,float4 current,float4 sum,float4 squares,float taps){
    float4 mean=sum/taps,sigma=sqrt(max(float4(0),squares/taps-mean*mean));
    return step(max(float4(.01f),2*sigma),abs(old-current));
}
static float4 radiance_innovation(float4 old,float4 current,float4 sum,float4 squares,float taps,float3 noise){
    float4 mean=sum/taps,variance=max(float4(0),squares/taps-mean*mean);
    variance.xyz=max(variance.xyz,noise);
    return step(max(float4(.01f),2*sqrt(variance)),abs(old-current));
}
static float4 rectify_radiance(float4 old,float4 minimum,float4 maximum,float4 sum,float4 squares,float taps,float3 noise){
    float4 mean=sum/taps,sigma=sqrt(max(float4(0),squares/taps-mean*mean));
    float4 margin=float4(3*sqrt(max(float3(0),noise)),0);
    return clamp(old,max(minimum-margin,mean-2*sigma-margin),min(maximum+margin,mean+2*sigma+margin));
}
kernel void resolve_temporal(constant TemporalParameters &t [[buffer(0)]],
    texture2d<float,access::read> currentVisibility [[texture(0)]],texture2d<float,access::read> currentReflection [[texture(1)]],
    texture2d<float,access::read> currentIndirect [[texture(2)]],texture2d<float,access::read> currentNormal [[texture(3)]],texture2d<float,access::read> currentPosition [[texture(4)]],
    texture2d<float,access::read> previousVisibility [[texture(5)]],texture2d<float,access::read> previousReflection [[texture(6)]],
    texture2d<float,access::read> previousIndirect [[texture(7)]],texture2d<float,access::read> previousNormal [[texture(8)]],texture2d<float,access::read> previousPosition [[texture(9)]],
    texture2d<float,access::write> outVisibility [[texture(10)]],texture2d<float,access::write> outReflection [[texture(11)]],
    texture2d<float,access::write> outIndirect [[texture(12)]],texture2d<float,access::write> outNormal [[texture(13)]],texture2d<float,access::write> outPosition [[texture(14)]],
    texture2d<float,access::write> motion [[texture(15)]],texture2d<float,access::read> currentLocal [[texture(16)]],
    texture2d<float,access::read> previousLocal [[texture(17)]],texture2d<float,access::write> outLocal [[texture(18)]],
    texture2d<float,access::read> currentReflectionVariance [[texture(19)]],texture2d<float,access::read> currentIndirectVariance [[texture(20)]],texture2d<float,access::read> currentLocalVariance [[texture(21)]],
    texture2d<float,access::read> previousReflectionVariance [[texture(22)]],texture2d<float,access::read> previousIndirectVariance [[texture(23)]],texture2d<float,access::read> previousLocalVariance [[texture(24)]],
    texture2d<float,access::write> outReflectionVariance [[texture(25)]],texture2d<float,access::write> outIndirectVariance [[texture(26)]],texture2d<float,access::write> outLocalVariance [[texture(27)]],texture2d<float,access::write> outRejection [[texture(28)]],uint2 pixel [[thread_position_in_grid]]) {
    if(any(pixel>=t.current.dimensions.xy))return;
    float4 visibility=currentVisibility.read(pixel),reflection=currentReflection.read(pixel),indirect=currentIndirect.read(pixel);
    float4 local=currentLocal.read(pixel);
    float4 rVariance=currentReflectionVariance.read(pixel),iVariance=currentIndirectVariance.read(pixel),lVariance=currentLocalVariance.read(pixel);
    float4 normal=currentNormal.read(pixel),position=currentPosition.read(pixel);float count=1;float4 vector=0;float rejection=1;
    if(t.history.x&&position.w>0&&visibility.w>0){
        float3 relative=position.xyz-t.previous_camera.xyz;
        float4 clip=t.previous_view_projection*float4(relative,1);
        float2 uv=clip.xy/clip.w*.5f+.5f;
        if(clip.w>0&&all(isfinite(uv))&&all(uv>=0)&&all(uv<1)){
            uint2 oldPixel=min(uint2(uv*float2(t.history.zw)*.5f),t.current.dimensions.xy-1);
            float4 oldPosition=previousPosition.read(oldPixel),oldNormal=previousNormal.read(oldPixel),oldVisibility=previousVisibility.read(oldPixel);
            float footprint=0;
            for(uint axis=0;axis<2;axis++){
                uint2 neighbor=min(pixel+(axis==0?uint2(1,0):uint2(0,1)),t.current.dimensions.xy-1);
                float4 point=currentPosition.read(neighbor);
                if(point.w==position.w)footprint=max(footprint,length(point.xyz-position.xyz));
            }
            float tolerance=max(max(.035f,visibility.z*.003f),min(.25f,footprint*.85f));
            bool valid=oldPosition.w==position.w&&oldPosition.w>0&&oldVisibility.w>0&&distance(oldPosition.xyz,position.xyz)<tolerance&&dot(normal.xyz,oldNormal.xyz)>.95f&&abs(normal.w-oldNormal.w)<.05f;
            // Previous minus current in full-resolution offscreen-target pixels.
            float2 currentUv=(float2(min(pixel*2+1,t.history.zw-1))+.5f)/float2(t.history.zw);
            vector.xy=(uv-currentUv)*float2(t.history.zw);
            if(t.dynamic.x&&t.dynamic.z&&position.w>float(t.dynamic.y))valid=false;
            if(valid){
                float4 oldIndirect=previousIndirect.read(oldPixel);float oldCount=oldIndirect.w;
                count=min(float(t.history.y),oldCount+1);float weight=1.f/count;
                float4 oldReflection=previousReflection.read(oldPixel),oldLocal=previousLocal.read(oldPixel);
                // Estimate only Monte Carlo noise, not changes in the expected signal.
                // Keep recent variance through frames where all sparse rays miss a light.
                float varianceWeight=max(weight,.125f);
                float4 oldRVariance=previousReflectionVariance.read(oldPixel),oldIVariance=previousIndirectVariance.read(oldPixel),oldLVariance=previousLocalVariance.read(oldPixel);
                float3 rNoise=max(rVariance.xyz,oldRVariance.xyz),iNoise=max(iVariance.xyz,oldIVariance.xyz),lNoise=max(lVariance.xyz,oldLVariance.xyz);
                rVariance=mix(oldRVariance,rVariance,varianceWeight);iVariance=mix(oldIVariance,iVariance,varianceWeight);lVariance=mix(oldLVariance,lVariance,varianceWeight);
                float4 vReactive=0,rReactive=0,iReactive=0,lReactive=0;
                if(t.dynamic.x){
                    float4 vmin=visibility,vmax=visibility,vsum=0,vsq=0;
                    float4 rmin=reflection,rmax=reflection,rsum=0,rsq=0;
                    float4 imin=indirect,imax=indirect,isum=0,isq=0;
                    float4 lmin=local,lmax=local,lsum=0,lsq=0;float taps=0;
                    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
                        int2 q=int2(pixel)+int2(x,y);if(any(q<0)||any(q>=int2(t.current.dimensions.xy)))continue;
                        float4 qp=currentPosition.read(uint2(q)),qn=currentNormal.read(uint2(q));
                        if(qp.w<=0||dot(qn.xyz,normal.xyz)<.95f||abs(qn.w-normal.w)>.05f||abs(dot(qp.xyz-position.xyz,normal.xyz))>.04f)continue;
                        if((qp.w>float(t.dynamic.y))!=(position.w>float(t.dynamic.y)))continue;
                        float4 v=currentVisibility.read(uint2(q)),r=currentReflection.read(uint2(q)),i=currentIndirect.read(uint2(q));
                        if(v.w<=0)continue;
                        vmin=min(vmin,v);vmax=max(vmax,v);vsum+=v;vsq+=v*v;
                        rmin=min(rmin,r);rmax=max(rmax,r);rsum+=r;rsq+=r*r;
                        imin=min(imin,i);imax=max(imax,i);isum+=i;isq+=i*i;
                        float4 l=currentLocal.read(uint2(q));lmin=min(lmin,l);lmax=max(lmax,l);lsum+=l;lsq+=l*l;taps++;
                    }
                    if(taps>0){
                        vReactive=history_innovation(oldVisibility,visibility,vsum,vsq,taps);
                        // Four-ray AO has discrete Monte Carlo variation. A broader
                        // innovation band avoids treating normal 0/1 samples as motion.
                        float aoMean=vsum.x/taps,aoSigma=sqrt(max(0.f,vsq.x/taps-aoMean*aoMean));
                        vReactive.x=step(max(.25f,3*aoSigma),abs(oldVisibility.x-visibility.x));
                        rReactive=radiance_innovation(oldReflection,reflection,rsum,rsq,taps,rNoise);
                        iReactive=radiance_innovation(oldIndirect,indirect,isum,isq,taps,iNoise);
                        lReactive=radiance_innovation(oldLocal,local,lsum,lsq,taps,lNoise);
                        oldLocal=rectify_radiance(oldLocal,lmin,lmax,lsum,lsq,taps,lNoise);
                        oldVisibility.xy=rectify_history(oldVisibility,vmin,vmax,vsum,vsq,taps).xy;
                        oldReflection=rectify_radiance(oldReflection,rmin,rmax,rsum,rsq,taps,rNoise);
                        oldIndirect.xyz=rectify_radiance(oldIndirect,imin,imax,isum,isq,taps,iNoise).xyz;
                    }
                    // Short responsive history bounds lag while preserving accumulation.
                    count=min(count,8.f);weight=1.f/count;
                }
                rejection=0;
                if(t.dynamic.x) {
                    bool physical=(t.current.dimensions.w&PHYSICAL_LIGHTING)!=0;
                    if(!physical&&t.current.controls.z>0)rejection=max(rejection,vReactive.x);
                    if(!physical&&t.current.controls.w>0)rejection=max(rejection,vReactive.y);
                    if(t.current.transport.x>0)rejection=max(rejection,max(rReactive.x,max(rReactive.y,rReactive.z)));
                    if(t.current.transport.y>0)rejection=max(rejection,max(iReactive.x,max(iReactive.y,iReactive.z)));
                    rejection=max(rejection,max(lReactive.x,max(lReactive.y,lReactive.z)));
                }
                visibility.xy=mix(oldVisibility.xy,visibility.xy,max(float2(weight),vReactive.xy));
                indirect.xyz=mix(oldIndirect.xyz,indirect.xyz,max(float3(weight),iReactive.xyz));
                local.xyz=mix(oldLocal.xyz,local.xyz,max(float3(weight),lReactive.xyz));
                float3 currentView=normalize(t.current.camera.xyz-position.xyz),previousView=normalize(t.previous_camera.xyz-position.xyz);
                float viewChange=length(currentView-previousView);
                // Glossy reflections change with viewpoint even when the primary surface stays fixed.
                float reflectionWeight=viewChange>.0001f?max(weight,mix(.5f,.1f,normal.w)):weight;
                reflection=mix(oldReflection,reflection,max(float4(reflectionWeight),rReactive));
                vector.z=1;
            }
        }
    }
    indirect.w=count;vector.w=count;outRejection.write(float4(rejection),pixel);
    outVisibility.write(visibility,pixel);outReflection.write(reflection,pixel);outIndirect.write(indirect,pixel);
    outNormal.write(normal,pixel);outPosition.write(position,pixel);motion.write(vector,pixel);outLocal.write(local,pixel);
    outReflectionVariance.write(rVariance,pixel);outIndirectVariance.write(iVariance,pixel);outLocalVariance.write(lVariance,pixel);
}

struct FullscreenVertex {float4 position [[position]];};
vertex FullscreenVertex visibility_vertex(uint id [[vertex_id]]) {
    float2 position=float2((id<<1)&2,id&2);
    return {float4(position*2-1,0,1)};
}
// Apply display exposure only after scene-linear reconstruction. Peak-channel
// compression preserves RGB ratios, rolls off highlights, and stays below one.
float3 display_radiance(float3 radiance,constant FrameParameters &p) {
    if(p.display.y==0)return radiance;
    float3 exposed=max(radiance,0.f)*exp2(p.display.x);
    return exposed/(1+max(exposed.x,max(exposed.y,exposed.z)));
}
fragment float4 visibility_composite(FullscreenVertex in [[stage_in]],
                                    texture2d<float,access::read> visibility [[texture(0)]],
                                    depth2d<float,access::read> depth [[texture(1)]],
                                    texture2d<float,access::read> reflections [[texture(2)]],texture2d<float,access::read> indirect [[texture(3)]],texture2d<float,access::read> base [[texture(4)]],
                                    texture2d<float,access::read> edgeVisibility [[texture(5)]],texture2d<float,access::read> edgeReflections [[texture(6)]],texture2d<float,access::read> edgeIndirect [[texture(7)]],texture2d<float,access::read> local [[texture(8)]],texture2d<float,access::read> edgeLocal [[texture(9)]],
                                    constant FrameParameters &p [[buffer(0)]]) {
    uint2 fullPixel=uint2(in.position.xy);
    float4 raster=base.read(fullPixel);
    float z=depth.read(fullPixel);
    float2 uv=(float2(fullPixel)+.5f)/float2(depth.get_width(),depth.get_height());
    float distance=z>0?length(frame_position(uv,z,p)):0;
    int2 center=int2(fullPixel/2);float2 sum=0;float weights=0,coverage=0;float4 reflection=0;float3 gi=0,direct=0;
    float4 refined=edgeVisibility.read(fullPixel);
    if(refined.w>=0){coverage=refined.w;sum=mix(float2(1),refined.xy,refined.w);weights=1;reflection=edgeReflections.read(fullPixel)*refined.w;gi=edgeIndirect.read(fullPixel).xyz*refined.w;direct=edgeLocal.read(fullPixel).xyz*refined.w;}
    else for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
        int2 coord=clamp(center+int2(x,y),int2(0),int2(p.dimensions.xy)-1);
        float4 value=visibility.read(uint2(coord));
        if(abs(value.z-distance)>max(.08f,distance*.004f))continue;
        float weight=1.f/(1+float(x*x+y*y));
        sum+=mix(float2(1),value.xy,value.w)*weight;weights+=weight;coverage+=value.w*weight;
        reflection+=reflections.read(uint2(coord))*value.w*weight;gi+=indirect.read(uint2(coord)).xyz*value.w*weight;direct+=local.read(uint2(coord)).xyz*value.w*weight;
    }
    float2 value=weights>0?sum/weights:float2(1);
    float factor=mix(1.f,value.x,p.controls.z)*mix(1.f,value.y,p.controls.w);
    if(weights>0){reflection/=weights;gi/=weights;direct/=weights;}
    float3 addition=reflection.xyz*p.transport.x+gi*p.transport.y+direct;
    // Preserve the existing visibility response, then combine new transport in linear light.
    float3 shaded=raster.xyz*factor;
    float3 linearBase=(p.dimensions.w&1u)==0?linear_rgb(shaded):shaded;
    float3 result=linearBase*(1-saturate(reflection.w*p.transport.x))+addition;
    if(p.dimensions.w&PHYSICAL_LIGHTING){
        float3 unlitRaster=(p.dimensions.w&1u)==0?linear_rgb(raster.xyz):raster.xyz;
        // Radiance above already carries coverage. Preserve raster pixels outside
        // the collected scene (sky, unsupported geometry and the radius transition).
        float cov=weights>0?saturate(coverage/weights):0.f;
        if(p.dimensions.w&16u) {
            // The raw MetalFX input alpha carries coverage, independently of its
            // reconstructed alpha. Presentation restores the original raster alpha.
            return float4(unlitRaster*(1-cov)+addition,cov);
        }
        float3 surface=cov>0?addition/cov:float3(0);
        result=unlitRaster*(1-cov)+display_radiance(surface,p)*cov;
    }
    return float4((p.dimensions.w&17u)==0?srgb_rgb(result):result,raster.w);
}
fragment float4 metalfx_present(FullscreenVertex in [[stage_in]],texture2d<float,access::read> denoised [[texture(0)]],
    texture2d<float,access::read> original [[texture(1)]],texture2d<float,access::read> bypass [[texture(2)]],texture2d<float,access::read> rasterBase [[texture(3)]],
    texture2d<float,access::read> reflectionNoise [[texture(4)]],texture2d<float,access::read> indirectNoise [[texture(5)]],texture2d<float,access::read> localNoise [[texture(6)]],
    constant FrameParameters &p [[buffer(0)]],constant uint &dynamicActive [[buffer(1)]]) {
    uint2 pixel=uint2(in.position.xy);float4 raw=original.read(pixel);
    float3 rgb=bypass.read(pixel).x>.5f?raw.xyz:denoised.read(pixel).xyz;
    // Never propagate invalid framework output to the game target.
    if(!all(isfinite(rgb)))rgb=raw.xyz;
    if(dynamicActive&&bypass.read(pixel).x<=.5f) {
        // A reactive mask alone does not guarantee removal of stale framework
        // output. Rectify its RGB against current samples before presentation.
        // Retained Monte Carlo variance protects valid sparse bright transport.
        float3 minimum=raw.xyz,maximum=raw.xyz,sum=0,squares=0;
        for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
            uint2 q=uint2(clamp(int2(pixel)+int2(x,y),int2(0),int2(original.get_width(),original.get_height())-1));
            float3 value=original.read(q).xyz;minimum=min(minimum,value);maximum=max(maximum,value);sum+=value;squares+=value*value;
        }
        uint2 q=min(pixel/2,p.dimensions.xy-1);
        // Sum standard deviations: conservative even when channels' estimators correlate.
        float3 deviation=sqrt(max(reflectionNoise.read(q).xyz,0.f))*p.transport.x
            +sqrt(max(indirectNoise.read(q).xyz,0.f))*p.transport.y+sqrt(max(localNoise.read(q).xyz,0.f));
        float3 mean=sum/9,sigma=sqrt(max(squares/9-mean*mean,0.f)),margin=3*deviation;
        rgb=clamp(rgb,max(float3(0),max(minimum-margin,mean-2*sigma-margin)),min(maximum+margin,mean+2*sigma+margin));
    }
    float4 raster=rasterBase.read(pixel);
    if(p.dimensions.w&PHYSICAL_LIGHTING) {
        float3 base=(p.dimensions.w&1u)==0?linear_rgb(raster.xyz):raster.xyz;
        float cov=saturate(raw.w);
        float3 surface=cov>0?max(rgb-base*(1-cov),0.f)/cov:float3(0);
        rgb=base*(1-cov)+display_radiance(surface,p)*cov;
    }
    return float4((p.dimensions.w&1u)==0?srgb_rgb(rgb):rgb,raster.w);
}
