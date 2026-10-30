/*
 * The complex synthesis functions (csc_int, csc_int_int, cot_int in
 * mb_osc_shapes.h) as Ruby methods of MB::FastSound::ComplexSynthesis.
 */
#ifndef MB_FAST_SOUND_COMPLEX_SYNTHESIS_H
#define MB_FAST_SOUND_COMPLEX_SYNTHESIS_H

#include <ruby.h>

// Defines MB::FastSound::ComplexSynthesis under +fast_sound+.
void mb_complex_synthesis_init(VALUE fast_sound);

#endif
