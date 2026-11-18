import Foundation

/// Metal shader source, compiled at startup so the app bundle needs no metallib.
enum ShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct GridVertex { float2 pos; float2 uv; float4 color; float4 kind; };
    struct GridUniforms { float2 viewport; float2 origin; float2 scale; float sharp; float pad; };
    struct GridOut { float4 position [[position]]; float2 uv; float4 color; float kind; };

    vertex GridOut grid_vertex(uint vid [[vertex_id]],
                               const device GridVertex* verts [[buffer(0)]],
                               constant GridUniforms& u [[buffer(1)]]) {
        GridVertex v = verts[vid];
        GridOut o;
        // Non-uniform cell scaling (fixed-grid modes) is applied around the grid origin.
        float2 p = u.origin + (v.pos - u.origin) * u.scale;
        o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
        o.uv = v.uv;
        o.color = v.color;
        o.kind = v.kind.x;
        return o;
    }

    fragment float4 grid_fragment(GridOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  sampler smp [[sampler(0)]],
                                  constant GridUniforms& u [[buffer(1)]]) {
        if (in.kind < 0.5) {
            return float4(in.color.rgb * in.color.a, in.color.a);
        }
        float2 uv = in.uv;
        if (u.sharp > 0.5) {
            // Sharp bilinear: sample at texel centres and blend only across the one-screen-pixel seam between
            // texels, so magnified bitmap pixels stay uniform even at non-integer scale factors.
            float2 ts = float2(atlas.get_width(), atlas.get_height());
            float2 p = uv * ts;
            float2 seam = floor(p + 0.5);
            float2 dudv = max(fwidth(p), float2(1e-5));
            p = seam + clamp((p - seam) / dudv, -0.5, 0.5);
            uv = p / ts;
        }
        float4 t = atlas.sample(smp, uv);
        if (in.kind < 1.5) {
            float a = t.a * in.color.a;
            return float4(in.color.rgb * a, a);
        }
        return float4(t.rgb * in.color.a, t.a * in.color.a);
    }

    struct FSOut { float4 position [[position]]; float2 uv; };

    vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        FSOut o;
        o.position = float4(p, 0.0, 1.0);
        o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return o;
    }

    fragment float4 downsample_fragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 ts = 1.0 / float2(src.get_width(), src.get_height());
        float3 c = src.sample(s, in.uv + ts * float2(-1.0, -1.0)).rgb
                 + src.sample(s, in.uv + ts * float2( 1.0, -1.0)).rgb
                 + src.sample(s, in.uv + ts * float2(-1.0,  1.0)).rgb
                 + src.sample(s, in.uv + ts * float2( 1.0,  1.0)).rgb;
        return float4(c * 0.25, 1.0);
    }

    struct BlurUniforms { float2 direction; float2 pad; };

    fragment float4 blur_fragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                                  constant BlurUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 ts = u.direction / float2(src.get_width(), src.get_height());
        float w0 = 0.227027, w1 = 0.1945946, w2 = 0.1216216, w3 = 0.054054, w4 = 0.016216;
        float3 c = src.sample(s, in.uv).rgb * w0;
        c += (src.sample(s, in.uv + ts * 1.0).rgb + src.sample(s, in.uv - ts * 1.0).rgb) * w1;
        c += (src.sample(s, in.uv + ts * 2.0).rgb + src.sample(s, in.uv - ts * 2.0).rgb) * w2;
        c += (src.sample(s, in.uv + ts * 3.0).rgb + src.sample(s, in.uv - ts * 3.0).rgb) * w3;
        c += (src.sample(s, in.uv + ts * 4.0).rgb + src.sample(s, in.uv - ts * 4.0).rgb) * w4;
        return float4(c, 1.0);
    }

    struct CRTUniforms {
        float2 resolution;
        float time;
        float curvature;
        float scanline;
        float scanlinePeriod;
        float glow;
        float vignette;
        float flicker;
        float noise;
        float brightness;
        float chromatic;
        float cornerRadius;
        float bellFlash;
        float2 pad;
    };

    static float rand2(float2 co) {
        return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 crt_fragment(FSOut in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> bloom [[texture(1)]],
                                 constant CRTUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        if (u.curvature > 0.0) {
            float2 c = uv * 2.0 - 1.0;
            c *= 1.0 + float2(c.y * c.y, c.x * c.x) * u.curvature;
            uv = c * 0.5 + 0.5;
        }
        float r = u.cornerRadius;
        float2 q = abs(uv - 0.5) - (0.5 - r);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        float px = 1.5 / u.resolution.y;
        float mask = 1.0 - smoothstep(-px, px, d);
        if (mask <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }

        float3 col;
        if (u.chromatic > 0.0) {
            float2 off = (uv - 0.5) * u.chromatic * 0.004;
            col = float3(scene.sample(s, uv + off).r, scene.sample(s, uv).g, scene.sample(s, uv - off).b);
        } else {
            col = scene.sample(s, uv).rgb;
        }
        if (u.glow > 0.0) {
            col += bloom.sample(s, uv).rgb * u.glow;
        }
        if (u.scanline > 0.0) {
            float y = uv.y * u.resolution.y;
            float sl = 0.5 + 0.5 * cos(y * 6.28318530718 / u.scanlinePeriod);
            col *= mix(1.0, sl, u.scanline);
        }
        if (u.vignette > 0.0) {
            float2 v = uv * (1.0 - uv);
            float vig = pow(clamp(v.x * v.y * 20.0, 0.0, 1.0), 0.3);
            col *= mix(1.0, vig, u.vignette);
        }
        if (u.flicker > 0.0) {
            float f = 1.0 + u.flicker * (0.025 * sin(u.time * 90.0) + 0.03 * (rand2(float2(floor(u.time * 60.0), 1.0)) - 0.5));
            col *= f;
        }
        if (u.noise > 0.0) {
            float n = rand2(uv * 300.0 + fract(u.time) * 10.0) - 0.5;
            col += n * u.noise * 0.08;
        }
        col *= u.brightness;
        col += u.bellFlash * 0.3;
        return float4(col * mask, 1.0);
    }
    """
}
