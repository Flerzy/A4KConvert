import Foundation

/// The final pass: samples the chain's `rgba16Float` result into the 8-bit BGRA
/// texture that goes back down the pipe.
///
/// Written here rather than in a `.metal` file so the package needs no Metal
/// toolchain at build time — everything compiles through `makeLibrary(source:)`,
/// the same path the translated Anime4K stages take.
enum ResolveKernel {
    static let functionName = "upscale_resolve"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler resolveSampler(
        coord::normalized, address::clamp_to_edge, filter::linear
    );

    kernel void \(functionName)(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        const uint2 size = uint2(destination.get_width(), destination.get_height());
        if (gid.x >= size.x || gid.y >= size.y) { return; }
        float2 pos = (float2(gid) + float2(0.5)) / float2(size);
        float4 color = source.sample(resolveSampler, pos);
        // The CNN passes can overshoot; 8-bit unorm would clamp anyway, but doing it
        // here keeps the behaviour explicit. Video has no alpha channel.
        destination.write(float4(clamp(color.rgb, 0.0, 1.0), 1.0), gid);
    }
    """
}
