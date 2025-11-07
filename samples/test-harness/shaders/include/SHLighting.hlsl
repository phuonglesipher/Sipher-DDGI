#ifndef SH_LIGHTING_HLSL
#define SH_LIGHTING_HLSL

#include "Common.hlsl"
#include "Descriptors.hlsl"
#include "SHCommon.hlsl"

float SpotAttenuation(float3 spotDirection, float3 lightDirection, float umbra, float penumbra)
{
    // Spot attenuation function from Frostbite, pg 115 in RTR4
    float cosTheta = saturate(dot(spotDirection, lightDirection));
    float t = saturate((cosTheta - cos(umbra)) / (cos(penumbra) - cos(umbra)));
    return t * t;
}

float LightWindowing(float distanceToLight, float maxDistance)
{
    return pow(saturate(1.f - pow((distanceToLight / maxDistance), 4)), 2);
}

float LightFalloff(float distanceToLight)
{
    return 1.f / pow(max(distanceToLight, 1.f), 2);
}

/**
 * Computes the visibility factor for a given vector to a light.
 */
float LightVisibility(
    Payload payload,
    float3 lightVector,
    float tmax,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh)
{
    RayDesc ray;
    ray.Origin = payload.worldPosition + (payload.normal * normalBias); // TODO: not using viewBias!
    ray.Direction = normalize(lightVector);
    ray.TMin = 0.f;
    ray.TMax = tmax;

    // Trace a visibility ray
    // Skip the CHS to avoid evaluating materials
    PackedPayload packedPayload = (PackedPayload)0;
    TraceRay(
        bvh,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
        0xFF,
        0,
        0,
        0,
        ray,
        packedPayload);

    return (packedPayload.hitT < 0.f);
}

/**
 * Evaluate direct lighting and showing for the current surface and the spot light.
 */
float3 EvaluateSpotLight(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights)
{
    float3 color = 0;
    for (uint lightIndex = 0; lightIndex < GetNumSpotLights(); lightIndex++)
    {
        // Get the index of the light
        uint index = (HasDirectionalLight() + lightIndex);

        // Load the spot light
        Light spotLight = lights[index];

        float3 lightVector = (spotLight.position - payload.worldPosition);
        float  lightDistance = length(lightVector);

        // Early out, light energy doesn't reach the surface
        if (lightDistance > spotLight.radius) return float3(0.f, 0.f, 0.f);

        float tmax = (lightDistance - viewBias);
        float visibility = LightVisibility(payload, lightVector, tmax, normalBias, viewBias, bvh);

        // Early out, this light isn't visible from the surface
        if (visibility <= 0.f) continue;

        // Compute lighting
        float3 lightDirection = normalize(lightVector);
        float  nol = max(dot(payload.normal, lightDirection), 0.f);
        float3 spotDirection = normalize(spotLight.direction);
        float  attenuation = SpotAttenuation(spotDirection, -lightDirection, spotLight.umbraAngle, spotLight.penumbraAngle);
        float  falloff = LightFalloff(lightDistance);
        float  window = LightWindowing(lightDistance, spotLight.radius);

        color += spotLight.power * spotLight.color * nol * attenuation * falloff * window * visibility;
    }
    return color;
}

/**
 * Evaluate direct lighting for the current surface and all influential point lights.
 */
float3 EvaluatePointLight(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights)
{
    float3 color = 0;
    for (uint lightIndex = 0; lightIndex < GetNumPointLights(); lightIndex++)
    {
        // Get the index of the point light
        uint index = HasDirectionalLight() + GetNumSpotLights();

        // Load the point light
        Light pointLight = lights[index];

        float3 lightVector = (pointLight.position - payload.worldPosition);
        float  lightDistance = length(lightVector);

        // Early out, light energy doesn't reach the surface
        if (lightDistance > pointLight.radius) return float3(0.f, 0.f, 0.f);

        float tmax = (lightDistance - viewBias);
        float visibility = LightVisibility(payload, lightVector, tmax, normalBias, viewBias, bvh);

        // Early out, this light isn't visible from the surface
        if (visibility <= 0.f) return float3(0.f, 0.f, 0.f);

        // Compute lighting
        float3 lightDirection = normalize(lightVector);
        float  nol = max(dot(payload.normal, lightDirection), 0.f);
        float  falloff = LightFalloff(lightDistance);
        float  window = LightWindowing(lightDistance, pointLight.radius);

        color += pointLight.power * pointLight.color * nol * falloff * window * visibility;
    }
    return color;
}

/**
 * Evaluate direct lighting for the current surface and the directional light.
 */
void EvaluateSHDirectionalLight(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights,
    inout FThreeBandSHVectorRGB RadianceSH)
{
    // Load the directional light data (directional light is always the first light)
    Light directionalLight = lights[0];

    float visibility = LightVisibility(payload, -directionalLight.direction, 1e27f, normalBias, viewBias, bvh);
    
    float3 lightDirection = -normalize(directionalLight.direction);
    if (visibility <= 0.f)
    {
        return;
    }

    // Compute lighting
    float  nol = max(dot(payload.shadingNormal, lightDirection), 0.f);
    float3 Color = directionalLight.power * directionalLight.color * nol * visibility;
    FThreeBandSHVector Temp = SHBasisFunction3(lightDirection);
    AddSH(RadianceSH, MulSH3(Temp, Color));
}

/**
 * Computes the diffuse reflection of light off the given surface (direct lighting).
 */
FThreeBandSHVectorRGB SHDirectDiffuseLighting(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights)
{
    float3 brdf = (payload.albedo / PI);

    FThreeBandSHVectorRGB RadianceSH = MulSH3(SHBasisFunction3(payload.shadingNormal), brdf);

    if (HasDirectionalLight())
    {
        EvaluateSHDirectionalLight(payload, normalBias, viewBias, bvh, lights, RadianceSH);
    }

    // if (GetNumSpotLights() > 0)
    // {
    //     lighting += EvaluateSpotLight(payload, normalBias, viewBias, bvh, lights);
    // }
    //
    // if (GetNumPointLights() > 0)
    // {
    //     lighting += EvaluatePointLight(payload, normalBias, viewBias, bvh, lights);
    // }

    return RadianceSH;
}
#endif // LIGHTING_HLSL
