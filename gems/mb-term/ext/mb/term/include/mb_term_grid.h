/*
 * The cell grid of MB::Term::FastTerm::Grid (mb-term's fast_term
 * extension), shared with extensions that draw into grids directly
 * (mb-sound's fast_ui composes plot canvases into them).
 *
 * Cells: a codepoint (0 for the right half of a wide character), packed
 * foreground and background colors (0xRRGGBB, MB_TERM_COLOR_INDEXED | n
 * for a palette index n, -1 for none), and attribute bits.
 *
 * mb_term_grid_get is exported by fast_term: load mb-term (require
 * 'mb/term') before an extension that calls it.
 */
#ifndef MB_TERM_GRID_H
#define MB_TERM_GRID_H

#include <stddef.h>
#include <stdint.h>
#include <ruby.h>

#define MB_TERM_ATTR_BOLD 1
#define MB_TERM_ATTR_REVERSE 2
#define MB_TERM_ATTR_UNDERLINE 4
#define MB_TERM_ATTR_ITALIC 8
#define MB_TERM_ATTR_DIM 16

// Colors with this bit are palette indexes (0..255) written as SGR
// indexes (30-37, 90-97, 38;5;n), so the terminal's own palette shows
// them (MB::Term::Cells::INDEXED)
#define MB_TERM_COLOR_INDEXED 0x1000000

// A growable byte buffer for encoding text
struct mb_term_outbuf {
	char *p;
	size_t len, cap;
};

// A direct-mapped cache of SGR sequences by style
#define MB_TERM_SGR_CACHE 64
struct mb_term_sgr_entry {
	int32_t f, b;
	int16_t a, mode; // mode -1: empty
	int8_t len;
	char seq[56];
};

struct mb_term_grid {
	long width, height;
	uint32_t *cp;
	int32_t *fg;
	int32_t *bg;
	uint8_t *attr;
	struct mb_term_outbuf out;       // encoding buffer, reused
	struct mb_term_sgr_entry *sgr;   // SGR cache (NULL until used)
};

// The grid of +self+ (an MB::Term::FastTerm::Grid or a subclass); raises
// TypeError for anything else and RuntimeError for a grid whose
// initialize didn't run.
__attribute__((visibility("default"))) struct mb_term_grid *mb_term_grid_get(VALUE self);

#endif
