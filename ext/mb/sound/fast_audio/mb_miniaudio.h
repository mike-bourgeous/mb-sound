/*
 * Includes miniaudio with the compile options shared by miniaudio_impl.c and
 * fast_audio.c (they must match, since they change struct layouts).  Only
 * device I/O is used; files are read and written with ffmpeg.
 *
 * Marked as a system header so that warnings inside third-party miniaudio
 * (e.g. from Ruby's -Wsuggest-attribute=format) don't fail the -Werror build,
 * while fast_audio.c itself is still checked.
 */
#ifndef MB_MINIAUDIO_H
#define MB_MINIAUDIO_H

#pragma GCC system_header

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.h"

#endif
