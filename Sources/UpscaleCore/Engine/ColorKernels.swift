import Foundation
import simd

/// One colour transform as the kernels see it: three matrix rows plus an offset.
///
/// Rows rather than a `float3x3` so the Swift and MSL layouts are unambiguous — each
/// `float3` is padded to 16 bytes on both sides, giving one 64-byte struct.
public struct ColorTransform: Equatable, Sendable {
    public var row0: SIMD3<Float>
    public var row1: SIMD3<Float>
    public var row2: SIMD3<Float>
    public var offset: SIMD3<Float>

    public init(rows: [SIMD3<Float>], offset: SIMD3<Float>) {
        precondition(rows.count == 3, "a colour transform has three rows")
        self.row0 = rows[0]
        self.row1 = rows[1]
        self.row2 = rows[2]
        self.offset = offset
    }

    /// Applies the transform the way `yuv420_to_rgb` does: subtract, then multiply.
    func applySubtractingOffset(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let centred = value - offset
        return SIMD3(dot(row0, centred), dot(row1, centred), dot(row2, centred))
    }

    /// Applies the transform the way `rgb_to_yuv420` does: multiply, then add.
    func applyAddingOffset(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(dot(row0, value), dot(row1, value), dot(row2, value)) + offset
    }
}

/// The two colour-conversion kernels at the ends of the chain.
///
/// Source strings rather than a `.metal` file, like `ResolveKernel`, so the package
/// still needs no Metal toolchain at build time.
enum ColorKernels {
    static let toRGBFunctionName = "yuv420_to_rgb"
    static let toYUVFunctionName = "rgb_to_yuv420"

    private static let transformStruct = """
    struct ColorTransform {
        float3 row0;
        float3 row1;
        float3 row2;
        float3 offset;
    };

    inline float3 apply(constant ColorTransform &t, float3 value) {
        return float3(dot(t.row0, value), dot(t.row1, value), dot(t.row2, value));
    }
    """

    /// Y at full size plus bilinearly upsampled chroma, into the chain's RGB.
    ///
    /// Chroma is sampled at the luma pixel's own normalised position, which is what mpv
    /// does and what the shaders were tuned against. Shifting the samples by a quarter
    /// chroma pixel for MPEG-2 siting was measured against ffmpeg's scaler and came out
    /// slightly *further* away, so the simple position stays.
    static let toRGBSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(transformStruct)

    constexpr sampler chromaSampler(
        coord::normalized, address::clamp_to_edge, filter::linear
    );

    kernel void \(toRGBFunctionName)(
        texture2d<float, access::read> luma [[texture(0)]],
        texture2d<float, access::sample> chromaBlue [[texture(1)]],
        texture2d<float, access::sample> chromaRed [[texture(2)]],
        texture2d<float, access::write> destination [[texture(3)]],
        constant ColorTransform &transform [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        const uint2 size = uint2(destination.get_width(), destination.get_height());
        if (gid.x >= size.x || gid.y >= size.y) { return; }

        const float2 chromaSize = float2(chromaBlue.get_width(), chromaBlue.get_height());
        const float2 chromaPos = (float2(gid) + float2(0.5)) * 0.5 / chromaSize;

        float3 yuv = float3(
            luma.read(gid).r,
            chromaBlue.sample(chromaSampler, chromaPos).r,
            chromaRed.sample(chromaSampler, chromaPos).r
        );
        float3 rgb = apply(transform, yuv - transform.offset);
        destination.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
    }
    """

    /// Writes the chain's result back out as planar 4:2:0.
    ///
    /// One thread per chroma sample: it writes the four luma samples of its 2x2 block
    /// and the one chroma pair, which is the average of those four pixels' chroma —
    /// the same box filter ffmpeg's scaler uses when it subsamples.
    static let toYUVSource = """
    #include <metal_stdlib>
    using namespace metal;

    \(transformStruct)

    constexpr sampler resolveSampler(
        coord::normalized, address::clamp_to_edge, filter::linear
    );

    kernel void \(toYUVFunctionName)(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> luma [[texture(1)]],
        texture2d<float, access::write> chromaBlue [[texture(2)]],
        texture2d<float, access::write> chromaRed [[texture(3)]],
        constant ColorTransform &transform [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        const uint2 chromaSize = uint2(chromaBlue.get_width(), chromaBlue.get_height());
        if (gid.x >= chromaSize.x || gid.y >= chromaSize.y) { return; }

        const uint2 lumaSize = uint2(luma.get_width(), luma.get_height());

        float2 chromaSum = float2(0.0);
        float weight = 0.0;
        for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
                const uint2 pixel = uint2(gid.x * 2 + dx, gid.y * 2 + dy);
                if (pixel.x >= lumaSize.x || pixel.y >= lumaSize.y) { continue; }
                // The chain may have landed on a different size than the output; the
                // resample is a plain sample, as the resolve pass used to do.
                const float2 pos = (float2(pixel) + float2(0.5)) / float2(lumaSize);
                const float3 rgb = clamp(source.sample(resolveSampler, pos).rgb, 0.0, 1.0);
                const float3 yuv = apply(transform, rgb) + transform.offset;
                luma.write(float4(yuv.x, 0.0, 0.0, 1.0), pixel);
                chromaSum += yuv.yz;
                weight += 1.0;
            }
        }
        const float2 chroma = chromaSum / max(weight, 1.0);
        chromaBlue.write(float4(chroma.x, 0.0, 0.0, 1.0), gid);
        chromaRed.write(float4(chroma.y, 0.0, 0.0, 1.0), gid);
    }
    """
}
