/*
 * MB::Sound::FastGenerative: counter-based dice for the generative layer
 * (MB::Sound::Generative::Dice; design/notes/generative.md).
 *
 * Every random number is a pure function of a seed and a path of keys:
 * the state starts as mix(seed) and each key folds in as
 * state = mix(state ^ key_of(key)), where mix is splitmix64's finalizer
 * (with its golden-ratio increment).  There is no generator state, so a
 * draw is the same whenever and wherever it's asked for: cycle 517 of a
 * generator comes out the same computed cold or after cycles 0..516.
 *
 * Keys: Integers (their low 64 bits, two's complement), Symbols and
 * Strings (64-bit FNV-1a over their bytes; Symbol#hash changes per
 * process), Rationals (mix(key(numerator)) ^ key(denominator)), and nil
 * (0).  Anything else raises ArgumentError (Floats would make draws depend
 * on rounding).
 *
 * Functions (states are Integers 0...2**64):
 *   start(seed)            mix(seed's low 64 bits)
 *   key(k)                 the 64-bit key of k
 *   fold(state, *keys)     the state after folding in each key
 *   rand(state, *keys)     a Float in 0...1 (53 bits) from fold(...)
 *   rands(state, count)    [rand(state, 0), ..., rand(state, count - 1)]
 *   pick(weights, u)       the index i where u * total first falls below
 *                          the running sum of the weights (an Array of
 *                          Floats, total by Array#sum's Kahan-Babuska
 *                          compensated summation), or -1 if none does
 *                          (zero or negative total, rounding at the end)
 *
 * The Ruby mirror (Generative::Dice with Dice.mode = :ruby) gives the same
 * results (specs compare them); built with -ffp-contract=off.
 */

#include <stdint.h>
#include <math.h>

#include <ruby.h>

#define FNV_OFFSET 0xcbf29ce484222325ULL
#define FNV_PRIME 0x100000001b3ULL

static ID id_numerator;
static ID id_denominator;

// splitmix64's output function, with the increment folded in.
static inline uint64_t gen_mix(uint64_t z)
{
	z += 0x9E3779B97F4A7C15ULL;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

static inline uint64_t gen_fnv(const char *p, long len)
{
	uint64_t h = FNV_OFFSET;
	for (long i = 0; i < len; i++) {
		h ^= (uint8_t)p[i];
		h *= FNV_PRIME;
	}
	return h;
}

// The low 64 bits of an Integer (two's complement for negative numbers).
static uint64_t gen_integer_bits(VALUE v)
{
	if (FIXNUM_P(v)) {
		return (uint64_t)(int64_t)FIX2LONG(v);
	}

	uint64_t out = 0;
	rb_integer_pack(v, &out, 1, sizeof(out), 0, INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER | INTEGER_PACK_2COMP);
	return out;
}

static uint64_t gen_key(VALUE k)
{
	if (FIXNUM_P(k) || RB_TYPE_P(k, T_BIGNUM)) {
		return gen_integer_bits(k);
	}
	if (SYMBOL_P(k)) {
		VALUE s = rb_sym2str(k);
		return gen_fnv(RSTRING_PTR(s), RSTRING_LEN(s));
	}
	if (RB_TYPE_P(k, T_STRING)) {
		return gen_fnv(RSTRING_PTR(k), RSTRING_LEN(k));
	}
	if (RB_TYPE_P(k, T_RATIONAL)) {
		uint64_t n = gen_key(rb_funcall(k, id_numerator, 0));
		uint64_t d = gen_key(rb_funcall(k, id_denominator, 0));
		return gen_mix(n) ^ d;
	}
	if (NIL_P(k)) {
		return 0;
	}

	rb_raise(rb_eArgError, "Dice keys are Integers, Symbols, Strings, Rationals, or nil (got %+"PRIsVALUE")", k);
}

static inline uint64_t gen_state(VALUE state)
{
	if (!RB_INTEGER_TYPE_P(state)) {
		rb_raise(rb_eTypeError, "A dice state is an Integer (got %+"PRIsVALUE")", state);
	}
	return gen_integer_bits(state);
}

static inline double gen_unit(uint64_t h)
{
	return (double)(h >> 11) * 0x1.0p-53;
}

static VALUE ruby_start(VALUE self, VALUE seed)
{
	if (!RB_INTEGER_TYPE_P(seed)) {
		rb_raise(rb_eTypeError, "A dice seed is an Integer (got %+"PRIsVALUE")", seed);
	}
	return ULL2NUM(gen_mix(gen_integer_bits(seed)));
}

static VALUE ruby_key(VALUE self, VALUE k)
{
	return ULL2NUM(gen_key(k));
}

static uint64_t gen_fold(VALUE state, int argc, const VALUE *argv)
{
	uint64_t h = gen_state(state);
	for (int i = 0; i < argc; i++) {
		h = gen_mix(h ^ gen_key(argv[i]));
	}
	return h;
}

static VALUE ruby_fold(int argc, VALUE *argv, VALUE self)
{
	rb_check_arity(argc, 1, UNLIMITED_ARGUMENTS);
	return ULL2NUM(gen_fold(argv[0], argc - 1, argv + 1));
}

static VALUE ruby_rand(int argc, VALUE *argv, VALUE self)
{
	rb_check_arity(argc, 1, UNLIMITED_ARGUMENTS);
	return DBL2NUM(gen_unit(gen_fold(argv[0], argc - 1, argv + 1)));
}

static VALUE ruby_rands(VALUE self, VALUE state, VALUE count)
{
	uint64_t h = gen_state(state);
	long n = NUM2LONG(count);
	if (n < 0) {
		rb_raise(rb_eArgError, "Dice count can't be negative (got %ld)", n);
	}

	VALUE out = rb_ary_new_capa(n);
	for (long i = 0; i < n; i++) {
		rb_ary_push(out, DBL2NUM(gen_unit(gen_mix(h ^ (uint64_t)(int64_t)i))));
	}
	return out;
}

// Array#sum's Kahan-Babuska summation for an Array of Floats (Integers
// are converted), so totals match Ruby's exactly.
static double gen_sum(VALUE weights, long n)
{
	double f = 0.0, c = 0.0;
	for (long i = 0; i < n; i++) {
		double x = NUM2DBL(RARRAY_AREF(weights, i));
		if (isnan(f)) {
			continue;
		}
		if (isnan(x)) {
			f = x;
			continue;
		}
		if (isinf(x)) {
			if (isinf(f) && signbit(x) != signbit(f)) {
				f = NAN;
			} else {
				f = x;
			}
			continue;
		}
		if (isinf(f)) {
			continue;
		}
		double t = f + x;
		if (fabs(f) >= fabs(x)) {
			c += ((f - t) + x);
		} else {
			c += ((x - t) + f);
		}
		f = t;
	}
	return f + c;
}

static VALUE ruby_pick(VALUE self, VALUE weights, VALUE u)
{
	Check_Type(weights, T_ARRAY);
	long n = RARRAY_LEN(weights);
	double total = gen_sum(weights, n);
	if (!(total > 0) || isinf(total)) {
		return LONG2NUM(-1);
	}

	double x = NUM2DBL(u) * total;
	for (long i = 0; i < n; i++) {
		x -= NUM2DBL(RARRAY_AREF(weights, i));
		if (x < 0) {
			return LONG2NUM(i);
		}
	}
	return LONG2NUM(-1);
}

void Init_fast_generative(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast = rb_define_module_under(sound, "FastGenerative");

	id_numerator = rb_intern("numerator");
	id_denominator = rb_intern("denominator");

	rb_define_module_function(fast, "start", ruby_start, 1);
	rb_define_module_function(fast, "key", ruby_key, 1);
	rb_define_module_function(fast, "fold", ruby_fold, -1);
	rb_define_module_function(fast, "rand", ruby_rand, -1);
	rb_define_module_function(fast, "rands", ruby_rands, 2);
	rb_define_module_function(fast, "pick", ruby_pick, 2);
}
