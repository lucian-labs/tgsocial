// Components — the depth drop's parallax (PROTOCOL.md §12.12 rule 10), as a SwiftUI layer effect.
//
// The same formula and constants as WaveLoop's WebGL fragment shader at waveloop.app/drop/, so a
// depth photo moves the same way there and here. `DepthParallax.sample` in Protocol/Drop.swift is
// this function on the CPU. `testDepthShaderDisplacesByTheMap` renders THIS shader over a gradient
// whose colour is its own coordinate and checks, pixel by pixel, that it sampled where that
// reference says — the displacement and the crop into the map, measured on the GPU's output.
// The map is read as its stored byte (0.9 is 0.9, not linearised), as WebGL reads it; measured.
//
// Needs Xcode's Metal toolchain (Xcode 26 ships it as a separate component:
// `xcodebuild -downloadComponent MetalToolchain`; docs/BUILDING.md §1, `make metal-check`). A
// per-pixel parallax at display rate is a GPU job; the CPU reference is a test oracle, not a
// fallback.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// `position` is the pixel in the layer, in points. `layer` is the colour image already cover-fit
/// into the box. `depth` is the map (near = white), `crop` the part of the map the box shows
/// (x, y, width, height in 0…1 — the same cover-fit as the colour image, since the map shares its
/// framing), `shift` = (cx·amp, cy·amp·0.6), `zoom` = 1 − 1.2·amp.
[[ stitchable ]] half4 dropDepthParallax(float2 position, SwiftUI::Layer layer, float2 size,
                                         texture2d<half> depth, float4 crop, float2 shift, float zoom) {
    float2 v = position / size;
    float2 uv = (v - 0.5) * zoom + 0.5;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float d = float(depth.sample(s, crop.xy + uv * crop.zw).r) - 0.5;
    float2 p = clamp(uv + shift * d, 0.002, 0.998);
    return layer.sample(p * size);
}
