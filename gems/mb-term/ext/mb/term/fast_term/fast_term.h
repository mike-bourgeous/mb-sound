/*
 * What fast_term's sources share inside the extension (not exported):
 * fast_term.c's grid type check and vt.c's Init.
 */
#ifndef MB_TERM_FAST_TERM_H
#define MB_TERM_FAST_TERM_H

#include <ruby.h>

#include "mb_term_grid.h"

// The grid of +v+ when it's an MB::Term::FastTerm::Grid (or a subclass),
// else NULL (never raises: VT#draw writes cells directly into native grids
// and calls #put_run on anything else)
struct mb_term_grid *mb_term_grid_or_null(VALUE v);

// Defines MB::Term::FastTerm::VT (vt.c)
void mb_term_init_vt(VALUE mFastTerm);

#endif
