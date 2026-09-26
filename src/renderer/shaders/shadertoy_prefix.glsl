#version 430 core

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
    uniform vec4  iSelection[3];
    uniform float iTimeCopy;
    uniform float iAudioRMS;
    uniform float iAudioPeak;
    uniform float iAudioBass;
    uniform float iAudioMid;
    uniform float iAudioTreble;
    uniform float iAudioDominantFreq;
    uniform vec4  iAudioSpectrum[32];
};

// The audio spectrum level at x in [0, 1] (30Hz to 16kHz on a log
// scale), interpolated between the 128 bands of iAudioSpectrum.
float audioSpectrum(float x) {
    float f = clamp(x, 0.0, 1.0) * 127.0;
    int i = int(f);
    int j = min(i + 1, 127);
    return mix(iAudioSpectrum[i / 4][i % 4], iAudioSpectrum[j / 4][j % 4], f - float(i));
}

#define CURSORSTYLE_BLOCK        0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR          2
#define CURSORSTYLE_UNDERLINE    3
#define CURSORSTYLE_LOCK         4

layout(binding = 0) uniform sampler2D iChannel0;

// These are unused currently by Ghostty:
// layout(binding = 1) uniform sampler2D iChannel1;
// layout(binding = 2) uniform sampler2D iChannel2;
// layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );
void main() { mainImage (_fragColor, gl_FragCoord.xy); }
