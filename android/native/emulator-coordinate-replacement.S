// Eight-byte in-place fragment, not a callable function. Emulator variant only.
// Input/output: s1; caller-saved scratch: w16 (upper x16 becomes zero).
.text
.p2align 2
.global kif_emulator_coordinate_replacement
kif_emulator_coordinate_replacement:
    fcvtzs w16, s1
    scvtf s1, w16
