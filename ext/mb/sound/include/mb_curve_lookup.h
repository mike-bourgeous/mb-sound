/*
 * Evaluating a tweening curve (MB::Sound::Curve) from its value table
 * (Curve#value_table): left and right values and slopes at cells + 1
 * nodes over 0..1.  Between nodes the curve is a cubic Hermite from the
 * right values of one node to the left values of the next; exactly on a
 * node it is the left value (so staircases jump just after each node, like
 * Curve.steps; within MB_CURVE_NODE_SNAP of a cell after it, as Curve.steps
 * snaps rounding).  Positions are clamped to 0..1 (NaN reads as 0).
 *
 * Shared by FastClip.curve_lookup (glides) and FastTexture.drift (curve
 * segments); the exact Ruby mirror is MB::Sound::Curve.lookup_ruby, so keep
 * the operations identical (users build with -ffp-contract=off).
 */
#ifndef MB_CURVE_LOOKUP_H
#define MB_CURVE_LOOKUP_H

#include <stddef.h>

#define MB_CURVE_NODE_SNAP 1e-6

// A curve's value table: +cells+ + 1 values in each array.
struct mb_curve_table {
	const double *fl;
	const double *fr;
	const double *dl;
	const double *dr;
	size_t cells;
};

// The curve's value at position +x+ (see the file comment).
static inline double mb_curve_lookup(const struct mb_curve_table *c, double x)
{
	double pos = x * (double)c->cells;
	if (!(pos > 0)) pos = 0; // also NaN
	if (pos > (double)c->cells) pos = (double)c->cells;
	size_t j = (size_t)pos;
	double u = pos - (double)j;
	if (u < MB_CURVE_NODE_SNAP) {
		return c->fl[j];
	}
	double h = 1.0 / (double)c->cells;
	double u2 = u * u, u3 = u2 * u;
	double h00 = 2.0 * u3 - 3.0 * u2 + 1.0;
	double h10 = u3 - 2.0 * u2 + u;
	double h01 = -2.0 * u3 + 3.0 * u2;
	double h11 = u3 - u2;
	return h00 * c->fr[j] + h10 * h * c->dr[j] + h01 * c->fl[j + 1] + h11 * h * c->dl[j + 1];
}

#endif
