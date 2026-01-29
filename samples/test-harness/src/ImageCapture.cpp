/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "ImageCapture.h"
#include "Common.h"

#if defined(_WIN32) || defined(WIN32)
#define STBI_MSC_SECURE_CRT
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <cmath>

namespace ImageCapture
{

    /**
     * Convert IEEE 754 half-precision float (16-bit) to single-precision float (32-bit).
     */
    inline float HalfToFloat(uint16_t h)
    {
        uint32_t sign = (h >> 15) & 0x1;
        uint32_t exponent = (h >> 10) & 0x1F;
        uint32_t mantissa = h & 0x3FF;

        if (exponent == 0)
        {
            if (mantissa == 0)
            {
                // Zero
                uint32_t result = sign << 31;
                return *reinterpret_cast<float*>(&result);
            }
            else
            {
                // Denormalized number
                while (!(mantissa & 0x400))
                {
                    mantissa <<= 1;
                    exponent--;
                }
                exponent++;
                mantissa &= ~0x400;
            }
        }
        else if (exponent == 31)
        {
            // Inf or NaN
            uint32_t result = (sign << 31) | 0x7F800000 | (mantissa << 13);
            return *reinterpret_cast<float*>(&result);
        }

        exponent = exponent + (127 - 15);
        mantissa = mantissa << 13;

        uint32_t result = (sign << 31) | (exponent << 23) | mantissa;
        return *reinterpret_cast<float*>(&result);
    }

    /**
     * Simple Reinhard tone mapping for HDR to LDR conversion.
     */
    inline float ToneMapReinhard(float hdr)
    {
        return hdr / (1.0f + hdr);
    }

    /**
     * Convert R16G16B16A16_FLOAT texture data to 8-bit RGBA with tone mapping.
     * This handles HDR values that WIC cannot properly convert.
     */
    bool ConvertHDRToLDR(
        uint32_t width,
        uint32_t height,
        uint64_t srcRowPitch,
        const unsigned char* pSrcData,
        std::vector<unsigned char>& converted)
    {
        converted.resize(width * height * 4);

        for (uint32_t y = 0; y < height; y++)
        {
            const uint16_t* srcRow = reinterpret_cast<const uint16_t*>(pSrcData + y * srcRowPitch);
            unsigned char* dstRow = converted.data() + y * width * 4;

            for (uint32_t x = 0; x < width; x++)
            {
                // Read RGBA as half-floats (4 x 16-bit)
                float r = HalfToFloat(srcRow[x * 4 + 0]);
                float g = HalfToFloat(srcRow[x * 4 + 1]);
                float b = HalfToFloat(srcRow[x * 4 + 2]);
                float a = HalfToFloat(srcRow[x * 4 + 3]);

                // Handle NaN/Inf
                if (!std::isfinite(r)) r = 0.0f;
                if (!std::isfinite(g)) g = 0.0f;
                if (!std::isfinite(b)) b = 0.0f;
                if (!std::isfinite(a)) a = 1.0f;

                // Apply exposure boost to make dim indirect lighting visible
                // This is for debug visualization only (values are typically 0.001-0.1 range)
                const float exposure = 200.0f;
                r = (std::max)(0.0f, r) * exposure;
                g = (std::max)(0.0f, g) * exposure;
                b = (std::max)(0.0f, b) * exposure;

                // Tone map RGB (HDR to LDR)
                r = ToneMapReinhard(r);
                g = ToneMapReinhard(g);
                b = ToneMapReinhard(b);
                a = (std::min)((std::max)(0.0f, a), 1.0f);

                // Convert to 8-bit
                dstRow[x * 4 + 0] = static_cast<unsigned char>(r * 255.0f + 0.5f);
                dstRow[x * 4 + 1] = static_cast<unsigned char>(g * 255.0f + 0.5f);
                dstRow[x * 4 + 2] = static_cast<unsigned char>(b * 255.0f + 0.5f);
                dstRow[x * 4 + 3] = static_cast<unsigned char>(a * 255.0f + 0.5f);
            }
        }

        return true;
    }

    /**
     * Write image data to a PNG format file.
     */
    bool CapturePng(std::string file, uint32_t width, uint32_t height, const unsigned char* data)
    {
        int result = stbi_write_png(file.c_str(), width, height, NumChannels, data, width * NumChannels);
        return result != 0;
    }

#if defined(_WIN32) || defined(WIN32)
    /**
     * Create a Windows Image Component (WIC) imaging factory.
     */
    IWICImagingFactory2* CreateWICImagingFactory()
    {
        static INIT_ONCE s_initOnce = INIT_ONCE_STATIC_INIT;

        IWICImagingFactory2* factory = nullptr;
        (void)InitOnceExecuteOnce(&s_initOnce,
            [](PINIT_ONCE, PVOID, PVOID* ifactory) -> BOOL
            {
                return SUCCEEDED(CoCreateInstance(
                    CLSID_WICImagingFactory2,
                    nullptr,
                    CLSCTX_INPROC_SERVER,
                    __uuidof(IWICImagingFactory2),
                    ifactory)) ? TRUE : FALSE;
            }, nullptr, reinterpret_cast<LPVOID*>(&factory));

        return factory;
    }

    /**
     * Convert the data format of a D3D resource using Windows Imaging Component (WIC).
     * For HDR formats (R16G16B16A16_FLOAT), uses custom tone-mapped conversion.
     */
    HRESULT ConvertTextureResource(
        const D3D12_RESOURCE_DESC desc,
        UINT64 imageSize,
        UINT64 dstRowPitch,
        unsigned char* pMappedMemory,
        std::vector<unsigned char>& converted)
    {
        // Use custom HDR to LDR conversion for R16G16B16A16_FLOAT
        // WIC doesn't properly handle HDR values > 1.0
        if (desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT)
        {
            if (ConvertHDRToLDR(
                static_cast<uint32_t>(desc.Width),
                static_cast<uint32_t>(desc.Height),
                dstRowPitch,
                pMappedMemory,
                converted))
            {
                return S_OK;
            }
            return E_FAIL;
        }

        bool sRGB = false;
        WICPixelFormatGUID pfGuid;

        // Determine source format's WIC equivalent
        switch (desc.Format)
        {
            case DXGI_FORMAT_R32G32B32A32_FLOAT:            pfGuid = GUID_WICPixelFormat128bppRGBAFloat; break;
            case DXGI_FORMAT_R16G16B16A16_UNORM:            pfGuid = GUID_WICPixelFormat64bppRGBA; break;
            case DXGI_FORMAT_R10G10B10_XR_BIAS_A2_UNORM:    pfGuid = GUID_WICPixelFormat32bppRGBA1010102XR; break;
            case DXGI_FORMAT_R10G10B10A2_UNORM:             pfGuid = GUID_WICPixelFormat32bppRGBA1010102; break;
            case DXGI_FORMAT_B5G5R5A1_UNORM:                pfGuid = GUID_WICPixelFormat16bppBGRA5551; break;
            case DXGI_FORMAT_B5G6R5_UNORM:                  pfGuid = GUID_WICPixelFormat16bppBGR565; break;
            case DXGI_FORMAT_R32_FLOAT:                     pfGuid = GUID_WICPixelFormat32bppGrayFloat; break;
            case DXGI_FORMAT_R16_FLOAT:                     pfGuid = GUID_WICPixelFormat16bppGrayHalf; break;
            case DXGI_FORMAT_R16_UNORM:                     pfGuid = GUID_WICPixelFormat16bppGray; break;
            case DXGI_FORMAT_R8_UNORM:                      pfGuid = GUID_WICPixelFormat8bppGray; break;
            case DXGI_FORMAT_A8_UNORM:                      pfGuid = GUID_WICPixelFormat8bppAlpha; break;
            case DXGI_FORMAT_R8G8B8A8_UNORM:                pfGuid = GUID_WICPixelFormat32bppRGBA; break;
            case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:           pfGuid = GUID_WICPixelFormat32bppRGBA; sRGB = true; break;
            case DXGI_FORMAT_B8G8R8A8_UNORM:                pfGuid = GUID_WICPixelFormat32bppBGRA; break;
            case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:           pfGuid = GUID_WICPixelFormat32bppBGRA; sRGB = true; break;
            case DXGI_FORMAT_B8G8R8X8_UNORM:                pfGuid = GUID_WICPixelFormat32bppBGR; break;
            case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:           pfGuid = GUID_WICPixelFormat32bppBGR; sRGB = true; break;
                // WIC does not have two-channel formats, four-channel lets us output all data for bitwise comparisons
            case DXGI_FORMAT_R32G32_FLOAT:                  pfGuid = GUID_WICPixelFormat128bppRGBAFloat; break;
            default:
                return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        }

        // Create an imaging factory
        IWICImagingFactory2* pWIC = CreateWICImagingFactory();

        // Create a WIC bitmap from the D3D resource
        IWICBitmap* bitmap = nullptr;
        HRESULT hr = pWIC->CreateBitmapFromMemory(
            static_cast<UINT>(desc.Width),
            static_cast<UINT>(desc.Height),
            pfGuid,
            static_cast<UINT>(dstRowPitch),
            static_cast<UINT>(imageSize),
            static_cast<BYTE*>(pMappedMemory),
            &bitmap);

        if(FAILED(hr)) return hr;

        // Create the WIC converter
        IWICFormatConverter* converter = nullptr;
        hr = pWIC->CreateFormatConverter(&converter);
        if(FAILED(hr))
        {
            SAFE_RELEASE(bitmap);
            return hr;
        }

        // Initialize the WIC converter
        hr = converter->Initialize(bitmap, GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr, 0.f, WICBitmapPaletteTypeCustom);
        if(FAILED(hr))
        {
            SAFE_RELEASE(converter);
            SAFE_RELEASE(bitmap);
            return hr;
        }

        // Convert the texels
        WICRect rect = { 0, 0, static_cast<INT>(desc.Width), static_cast<INT>(desc.Height) };
        hr = converter->CopyPixels(&rect, static_cast<UINT>(desc.Width * 4), static_cast<UINT>(converted.size()), converted.data());

        // Clean up
        SAFE_RELEASE(converter);
        SAFE_RELEASE(bitmap);

        return hr;
    }

#endif

}
