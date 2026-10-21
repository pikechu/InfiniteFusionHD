// Candidate helper for a future SOURCE build of the emulator-only variant.
// Do not enable this macro for the ordinary ARM phone build.
#pragma once

#if defined(KIF_ANDROID_EMULATOR_GPR_CONVERSIONS)
#if !defined(__ANDROID__) || !defined(__aarch64__)
#error "The emulator coordinate workaround is only for Android AArch64"
#endif
static inline float kifEmulatorCoordinateIntegerRoundtrip(float input) {
    int temporary;
    float result;
    __asm__ volatile(
        "fcvtzs %w0, %s2\n\t"
        "scvtf %s1, %w0"
        : "=&r"(temporary), "=w"(result)
        : "w"(input));
    (void)temporary;
    return result;
}
#endif
