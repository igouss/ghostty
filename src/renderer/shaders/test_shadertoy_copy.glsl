// Test shader for iSelection and iTimeCopy.
// Traces the copied selection with an outline, a soft halo and a sweep of
// light, then fades out. It doubles as a usable copy-feedback shader.

const float DURATION = 0.65;

// Signed distance to a selection rectangle (xy = -X,+Y corner, zw = size),
// inflated slightly past the cells and with rounded corners.
float selectionBox(vec2 p, vec4 r) {
    vec2 center = vec2(r.x + r.z * 0.5, r.y - r.w * 0.5);
    vec2 q = abs(p - center) - (r.zw * 0.5 + 2.0) + 3.0;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 3.0;
}

float smoothUnion(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 terminal = texture(iChannel0, fragCoord / iResolution.xy);
    float t = (iTime - iTimeCopy) / DURATION;
    if (iTimeCopy <= 0.0 || t >= 1.0 || iSelection[0].z <= 0.0) {
        fragColor = terminal;
        return;
    }

    float d = 1e9;
    vec2 lo = vec2(1e9);
    vec2 hi = vec2(-1e9);
    for (int i = 0; i < 3; i++) {
        vec4 r = iSelection[i];
        if (r.z <= 0.0) continue;
        d = smoothUnion(d, selectionBox(fragCoord, r), 6.0);
        lo = min(lo, vec2(r.x, r.y - r.w));
        hi = max(hi, vec2(r.x + r.z, r.y));
    }

    float fadeIn = smoothstep(0.0, 0.08, t);
    float fadeOut = 1.0 - smoothstep(0.35, 1.0, t);

    float outline = exp(-abs(d) / 0.9) * 0.85;
    float halo = exp(-max(d, 0.0) / 7.0) * step(0.0, d) * 0.30;
    float inside = 1.0 - smoothstep(-1.0, 0.5, d);

    // Light sweeps left to right across the selection's bounding box.
    vec2 size = max(hi - lo, vec2(1.0));
    float u = (fragCoord.x - lo.x + (hi.y - fragCoord.y) * 0.5) / (size.x + size.y * 0.5);
    float head = mix(-0.3, 1.3, 1.0 - pow(1.0 - t, 2.0));
    float band = exp(-pow((u - head) / 0.12, 2.0));

    float a = (outline + halo + inside * 0.06) * fadeIn * fadeOut
            + band * inside * 0.22 * fadeOut;
    vec3 tint = mix(iPalette[4], vec3(1.0), band * 0.4);
    fragColor = vec4(mix(terminal.rgb, tint, clamp(a, 0.0, 1.0)), terminal.a);
}
