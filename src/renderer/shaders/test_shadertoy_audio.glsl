// Audio-reactive example: spectrum bars behind the text along the
// bottom of the window, and a glow at the edges that pulses with the bass.
// Needs `custom-shader-audio = true`.

const float BAR_HEIGHT = 0.25;  // fraction of the window height
const float BARS = 64.0;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);
    vec3 accent = iPalette[4];

    // Bars: sample the spectrum at the center of each bar.
    float bar = floor(uv.x * BARS);
    float level = audioSpectrum((bar + 0.5) / BARS);
    float gap = step(0.15, fract(uv.x * BARS));
    float y = uv.y;
    float inBar = gap * step(y, level * BAR_HEIGHT);
    float fade = 1.0 - y / BAR_HEIGHT;
    vec3 barColor = mix(accent, iPalette[5], uv.x);

    // Edge glow driven by the bass.
    vec2 edge = min(uv, 1.0 - uv);
    float glow = exp(-min(edge.x, edge.y) * 40.0) * pow(iAudioBass, 4.0);

    vec3 color = term.rgb;
    color = mix(color, barColor, inBar * fade * 0.35);
    color += accent * glow * 0.5;
    fragColor = vec4(color, term.a);
}
