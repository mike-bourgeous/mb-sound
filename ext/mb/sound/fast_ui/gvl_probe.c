/*
 * MB::Sound::FastUI::GVLProbe: measures how long chosen threads wait for
 * the GVL and how long they hold it, from Ruby's internal thread event hook
 * (ruby/thread.h, Ruby 3.3+).  The terminal UI's painter shares the GVL
 * with the Session's render thread; this is how its cost to the render
 * thread is measured (bin/ui_demo.rb, the painter timing spec).
 *
 * - wait: READY (the thread can run again, e.g. its blocking write or sleep
 *   returned) to RESUMED (it holds the GVL): the render thread's "wake
 *   delay".
 * - hold: RESUMED to SUSPENDED (it gave the GVL up): how long a thread kept
 *   others waiting.
 * - blockers: for waits of 1 ms or more, which watched thread held the GVL
 *   when the waiting thread became ready.
 *
 * This is instrumentation, not a signal kernel: Ruby code can't observe
 * these events, so there is no Ruby mirror.  The hook runs on the thread
 * that has the event, without the GVL; each watched thread's slot is
 * written only by events of that thread, and Ruby reads the recorded
 * values from a fixed ring (a read racing a write may see one stale
 * value, which statistics tolerate).
 */
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <ruby.h>
#include <ruby/thread.h>

#define PROBE_SLOTS 4
#define PROBE_RING 65536
#define PROBE_BLOCKERS 4096

// Waits of at least this long record which watched thread held the GVL
// when the waiting thread became ready.
#define PROBE_BLOCKER_NS 1000000

struct probe_slot {
	VALUE thread;
	int64_t ready_ns;
	int64_t resumed_ns;
	uint64_t wait_count;
	uint64_t hold_count;
	int32_t waits[PROBE_RING]; // nanoseconds, capped at 2.1 s
	int32_t holds[PROBE_RING];
	int holder_at_ready;
	uint64_t blocker_count;
	int32_t blocker_waits[PROBE_BLOCKERS];
	int8_t blockers[PROBE_BLOCKERS];
};

// The watched slot holding the GVL (-1 for none or an unwatched thread).
// Only the thread holding the GVL changes it (RESUMED, then SUSPENDED).
static int probe_holder = -1;

static struct probe_slot probe_slots[PROBE_SLOTS];
static int probe_slot_count;
static rb_internal_thread_event_hook_t *probe_hook;
static VALUE probe_threads; // keeps the watched Thread objects alive

static int64_t probe_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Durations are kept in nanoseconds, capped at INT32_MAX (2.1 s).
static int32_t probe_clamp(int64_t ns)
{
	if (ns < 0) {
		return 0;
	}
	return ns > INT32_MAX ? INT32_MAX : (int32_t)ns;
}

static void probe_event(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data)
{
	VALUE thread = data->thread;
	for (int i = 0; i < probe_slot_count; i++) {
		struct probe_slot *s = &probe_slots[i];
		if (s->thread != thread) {
			continue;
		}

		int64_t now = probe_now();
		if (event & RUBY_INTERNAL_THREAD_EVENT_READY) {
			s->ready_ns = now;
			s->holder_at_ready = probe_holder;
		} else if (event & RUBY_INTERNAL_THREAD_EVENT_RESUMED) {
			if (s->ready_ns) {
				int32_t wait = probe_clamp(now - s->ready_ns);
				s->waits[s->wait_count % PROBE_RING] = wait;
				s->wait_count++;
				s->ready_ns = 0;
				if (wait >= PROBE_BLOCKER_NS) {
					s->blocker_waits[s->blocker_count % PROBE_BLOCKERS] = wait;
					s->blockers[s->blocker_count % PROBE_BLOCKERS] = (int8_t)s->holder_at_ready;
					s->blocker_count++;
				}
			}
			s->resumed_ns = now;
			probe_holder = i;
		} else if (event & RUBY_INTERNAL_THREAD_EVENT_SUSPENDED) {
			if (s->resumed_ns) {
				s->holds[s->hold_count % PROBE_RING] = probe_clamp(now - s->resumed_ns);
				s->hold_count++;
				s->resumed_ns = 0;
			}
			if (probe_holder == i) {
				probe_holder = -1;
			}
		}
		return;
	}
}

/*
 * GVLProbe.start(threads) -> threads: watches up to 4 Threads (replacing
 * any watched before) and clears their records.
 */
static VALUE probe_start(VALUE self, VALUE threads)
{
	Check_Type(threads, T_ARRAY);
	long n = RARRAY_LEN(threads);
	if (n < 1 || n > PROBE_SLOTS) {
		rb_raise(rb_eArgError, "GVLProbe watches 1 to %d threads (got %ld)", PROBE_SLOTS, n);
	}
	for (long i = 0; i < n; i++) {
		if (!rb_obj_is_kind_of(RARRAY_AREF(threads, i), rb_cThread)) {
			rb_raise(rb_eTypeError, "GVLProbe.start takes Threads");
		}
	}

	if (probe_hook) {
		rb_internal_thread_remove_event_hook(probe_hook);
		probe_hook = NULL;
	}

	rb_ary_clear(probe_threads);
	probe_slot_count = 0;
	for (int i = 0; i < PROBE_SLOTS && i < (int)n; i++) {
		struct probe_slot *s = &probe_slots[i];
		memset(s, 0, sizeof(*s));
		s->thread = RARRAY_AREF(threads, i);
		s->holder_at_ready = -1;
		rb_ary_push(probe_threads, s->thread);
	}
	probe_slot_count = (int)n;
	probe_holder = -1;

	probe_hook = rb_internal_thread_add_event_hook(
		probe_event,
		RUBY_INTERNAL_THREAD_EVENT_READY | RUBY_INTERNAL_THREAD_EVENT_RESUMED | RUBY_INTERNAL_THREAD_EVENT_SUSPENDED,
		NULL
	);

	return threads;
}

// GVLProbe.stop -> nil: removes the hook (the records stay readable).
static VALUE probe_stop(VALUE self)
{
	if (probe_hook) {
		rb_internal_thread_remove_event_hook(probe_hook);
		probe_hook = NULL;
	}
	return Qnil;
}

// GVLProbe.active? -> true while the hook is installed.
static VALUE probe_active(VALUE self)
{
	return probe_hook ? Qtrue : Qfalse;
}

static VALUE probe_values(const int32_t *ring, uint64_t count)
{
	uint64_t n = count < PROBE_RING ? count : PROBE_RING;
	VALUE out = rb_ary_new_capa((long)n);
	for (uint64_t k = count - n; k < count; k++) {
		rb_ary_push(out, DBL2NUM(ring[k % PROBE_RING] * 1e-9));
	}
	return out;
}

static struct probe_slot *probe_slot(VALUE index)
{
	int i = NUM2INT(index);
	if (i < 0 || i >= probe_slot_count) {
		rb_raise(rb_eIndexError, "No GVLProbe slot %d (%d watched)", i, probe_slot_count);
	}
	return &probe_slots[i];
}

// GVLProbe.waits(i) -> Array of seconds: watched thread i's GVL waits
// (the newest 65536).
static VALUE probe_waits(VALUE self, VALUE index)
{
	struct probe_slot *s = probe_slot(index);
	return probe_values(s->waits, s->wait_count);
}

// GVLProbe.holds(i) -> Array of seconds: watched thread i's GVL holds.
static VALUE probe_holds(VALUE self, VALUE index)
{
	struct probe_slot *s = probe_slot(index);
	return probe_values(s->holds, s->hold_count);
}

// GVLProbe.blockers(i) -> Array of [seconds, slot]: watched thread i's
// waits of 1 ms or more, each with the watched slot that held the GVL when
// it became ready (-1: none of the watched threads, e.g. the GC or an
// unwatched thread).
static VALUE probe_blockers(VALUE self, VALUE index)
{
	struct probe_slot *s = probe_slot(index);
	uint64_t count = s->blocker_count;
	uint64_t n = count < PROBE_BLOCKERS ? count : PROBE_BLOCKERS;
	VALUE out = rb_ary_new_capa((long)n);
	for (uint64_t k = count - n; k < count; k++) {
		rb_ary_push(out, rb_assoc_new(DBL2NUM(s->blocker_waits[k % PROBE_BLOCKERS] * 1e-9), INT2NUM(s->blockers[k % PROBE_BLOCKERS])));
	}
	return out;
}

void mb_fast_ui_init_gvl_probe(VALUE mFastUI)
{
	probe_threads = rb_ary_new();
	rb_gc_register_address(&probe_threads);

	VALUE mProbe = rb_define_module_under(mFastUI, "GVLProbe");
	rb_define_module_function(mProbe, "start", probe_start, 1);
	rb_define_module_function(mProbe, "stop", probe_stop, 0);
	rb_define_module_function(mProbe, "active?", probe_active, 0);
	rb_define_module_function(mProbe, "waits", probe_waits, 1);
	rb_define_module_function(mProbe, "holds", probe_holds, 1);
	rb_define_module_function(mProbe, "blockers", probe_blockers, 1);
}
