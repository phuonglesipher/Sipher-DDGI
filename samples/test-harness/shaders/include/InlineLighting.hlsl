/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#ifndef INLINE_LIGHTING_HLSL
#define INLINE_LIGHTING_HLSL

#include "Common.hlsl"
#include "Descriptors.hlsl"

// ============================================================================
// Inline Ray Tracing Visibility Functions
// ============================================================================

/**
 * Computes the visibility factor for a given vector to a light using inline ray tracing (RayQuery).
 * Returns 1.0 if visible, 0.0 if occluded.
 */
float LightVisibilityInline(
    Payload payload,
    float3 lightVector,
    float tmax,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh)
{
    RayDesc ray;
    ray.Origin = payload.worldPosition + (payload.normal * normalBias);
    ray.Direction = normalize(lightVector);
    ray.TMin = 0.f;
    ray.TMax = tmax;

    // Use RayQuery for inline ray tracing
    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> RQuery;
    RQuery.TraceRayInline(
        bvh,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        0xFF,
        ray);
    RQuery.Proceed();

    // If no hit committed, the light is visible
    return (RQuery.CommittedStatus() == COMMITTED_NOTHING) ? 1.f : 0.f;
}

/**
 * Trace a visibility ray and return whether it hit anything (for shadow testing).
 * Returns true if occluded, false if visible.
 */
bool TraceVisibilityRayInline(
    float3 origin,
    float3 direction,
    float tmin,
    float tmax,
    RaytracingAccelerationStructure bvh)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = direction;
    ray.TMin = tmin;
    ray.TMax = tmax;

    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> RQuery;
    RQuery.TraceRayInline(
        bvh,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        0xFF,
        ray);
    RQuery.Proceed();

    return (RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT);
}

// ============================================================================
// Light Evaluation Functions (using inline visibility)
// ============================================================================

float SpotAttenuationInline(float3 spotDirection, float3 lightDirection, float umbra, float penumbra)
{
    // Spot attenuation function from Frostbite, pg 115 in RTR4
    float cosTheta = saturate(dot(spotDirection, lightDirection));
    float t = saturate((cosTheta - cos(umbra)) / (cos(penumbra) - cos(umbra)));
    return t * t;
}

float LightWindowingInline(float distanceToLight, float maxDistance)
{
    return pow(saturate(1.f - pow((distanceToLight / maxDistance), 4)), 2);
}

float LightFalloffInline(float distanceToLight)
{
    return 1.f / pow(max(distanceToLight, 1.f), 2);
}

/**
 * Evaluate direct lighting and shadowing for the current surface and the spot light (inline version).
 */
float3 EvaluateSpotLightInline(
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
        if (lightDistance > spotLight.radius) continue;

        float tmax = (lightDistance - viewBias);
        float visibility = LightVisibilityInline(payload, lightVector, tmax, normalBias, viewBias, bvh);

        // Early out, this light isn't visible from the surface
        if (visibility <= 0.f) continue;

        // Compute lighting
        float3 lightDirection = normalize(lightVector);
        float  nol = max(dot(payload.normal, lightDirection), 0.f);
        float3 spotDirection = normalize(spotLight.direction);
        float  attenuation = SpotAttenuationInline(spotDirection, -lightDirection, spotLight.umbraAngle, spotLight.penumbraAngle);
        float  falloff = LightFalloffInline(lightDistance);
        float  window = LightWindowingInline(lightDistance, spotLight.radius);

        color += spotLight.power * spotLight.color * nol * attenuation * falloff * window * visibility;
    }
    return color;
}

/**
 * Evaluate direct lighting for the current surface and all influential point lights (inline version).
 */
float3 EvaluatePointLightInline(
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
        uint index = HasDirectionalLight() + GetNumSpotLights() + lightIndex;

        // Load the point light
        Light pointLight = lights[index];

        float3 lightVector = (pointLight.position - payload.worldPosition);
        float  lightDistance = length(lightVector);

        // Early out, light energy doesn't reach the surface
        if (lightDistance > pointLight.radius) continue;

        float tmax = (lightDistance - viewBias);
        float visibility = LightVisibilityInline(payload, lightVector, tmax, normalBias, viewBias, bvh);

        // Early out, this light isn't visible from the surface
        if (visibility <= 0.f) continue;

        // Compute lighting
        float3 lightDirection = normalize(lightVector);
        float  nol = max(dot(payload.normal, lightDirection), 0.f);
        float  falloff = LightFalloffInline(lightDistance);
        float  window = LightWindowingInline(lightDistance, pointLight.radius);

        color += pointLight.power * pointLight.color * nol * falloff * window * visibility;
    }
    return color;
}

/**
 * Evaluate direct lighting for the current surface and the directional light (inline version).
 */
float3 EvaluateDirectionalLightInline(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights)
{
    // Load the directional light data (directional light is always the first light)
    Light directionalLight = lights[0];

    float visibility = LightVisibilityInline(payload, -directionalLight.direction, 1e27f, normalBias, viewBias, bvh);

    // Early out, the light isn't visible from the surface
    if (visibility <= 0.f) return float3(0.f, 0.f, 0.f);

    // Compute lighting
    float3 lightDirection = -normalize(directionalLight.direction);
    float  nol = max(dot(payload.shadingNormal, lightDirection), 0.f);

    return directionalLight.power * directionalLight.color * nol * visibility;
}

/**
 * Computes the diffuse reflection of light off the given surface (direct lighting) using inline ray tracing.
 */
float3 DirectDiffuseLightingInline(
    Payload payload,
    float normalBias,
    float viewBias,
    RaytracingAccelerationStructure bvh,
    StructuredBuffer<Light> lights)
{
    float3 brdf = (payload.albedo / PI);
    float3 lighting = 0.f;

    if (HasDirectionalLight())
    {
        lighting += EvaluateDirectionalLightInline(payload, normalBias, viewBias, bvh, lights);
    }

    if (GetNumSpotLights() > 0)
    {
        lighting += EvaluateSpotLightInline(payload, normalBias, viewBias, bvh, lights);
    }

    if (GetNumPointLights() > 0)
    {
        lighting += EvaluatePointLightInline(payload, normalBias, viewBias, bvh, lights);
    }

    return (brdf * lighting);
}

#endif // INLINE_LIGHTING_HLSL
