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
 *
 * The log (GVLProbe.log_start, dropout-probe-1; MB::Sound::DropoutProbe)
 * adds timestamps: each time a watched thread gets the GVL back after
 * being off it (blocked: SUSPENDED to READY) or waiting for it (READY to
 * RESUMED) at least the log's threshold, one record with all three times;
 * and each GC step (an internal GC_ENTER/GC_EXIT TracePoint: no ISEQ
 * events, so YJIT keeps its code) at least the GC threshold long, with
 * the watched thread that ran it.  Records are pushed at RESUMED and in the
 * GC hook, both with the GVL held, and drained with it, so the log needs no
 * atomics.
 *
 * Stacks (GVLProbe.stacks_start, gvl-main-1): where a thread was while it
 * kept a waiting thread off the GVL.  A native watchdog thread (no GVL)
 * checks every millisecond whether the waiter (the render thread) has
 * waited at least the threshold; if so it signals the watched thread
 * holding the GVL, whose handler records its native backtrace
 * (backtrace(3), resolved later with dladdr) and, optionally, its Ruby
 * frames (rb_profile_frames, the labels and paths copied as text in the
 * handler, as sampling profilers do).  A hold in C code (a C extension, a
 * system call that keeps the GVL, the VM itself) is never interrupted by
 * Ruby's timeslice; this says which code it was.  Opt-in instrumentation
 * (MB::Sound::DropoutProbe stacks:).
 */
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <dlfcn.h>
#include <execinfo.h>

#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/debug.h>
#include <stdlib.h>

#define PROBE_SLOTS 6
#define PROBE_RING 65536
#define PROBE_BLOCKERS 4096

// Waits of at least this long record which watched thread held the GVL
// when the waiting thread became ready.
#define PROBE_BLOCKER_NS 1000000

struct probe_slot {
	VALUE thread;
	int64_t ready_ns;
	int64_t resumed_ns;
	int64_t suspended_ns; // (for the log)
	uint64_t wait_count;
	uint64_t hold_count;
	int32_t waits[PROBE_RING]; // nanoseconds, capped at 2.1 s
	int32_t holds[PROBE_RING];
	int holder_at_ready;
	pthread_t pthread; // (the native thread, set at RESUMED, for stacks)
	int has_pthread;
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

// The log (see the top): a ring of records, overwritten oldest first when
// the reader falls behind (counted in log_lost).
struct log_record {
	int64_t a_ns; // :thread suspended (0: unknown); :gc entered
	int64_t b_ns; // :thread ready; :gc exited
	int64_t c_ns; // :thread resumed; :gc 0
	int64_t gc_count; // rb_gc_count() after the record
	int8_t kind; // 0 thread, 1 gc
	int8_t slot; // watched slot (-1: another thread, for GC)
	int8_t holder; // :thread: the slot holding the GVL when it became ready
};
#define LOG_THREAD 0
#define LOG_GC 1

static struct log_record *log_ring;
static uint64_t log_cap; // a power of two
static uint64_t log_head;
static uint64_t log_tail;
static uint64_t log_lost;
static int log_on;
static int64_t log_threshold_ns;
static int64_t log_gc_threshold_ns;
static VALUE log_gc_tracepoint = Qnil;
static int64_t log_gc_enter_ns;
static uint64_t log_gc_steps; // every GC step while logging
static int64_t log_gc_total_ns;
static int64_t log_gc_max_ns;

static void log_push(const struct log_record *r)
{
	if (log_head - log_tail >= log_cap) {
		log_tail++;
		log_lost++;
	}
	log_ring[log_head & (log_cap - 1)] = *r;
	log_head++;
}

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
			if (log_on && s->ready_ns &&
				((s->suspended_ns && s->ready_ns - s->suspended_ns >= log_threshold_ns) || now - s->ready_ns >= log_threshold_ns)) {
				struct log_record r = {
					.a_ns = s->suspended_ns,
					.b_ns = s->ready_ns,
					.c_ns = now,
					.gc_count = (int64_t)rb_gc_count(),
					.kind = LOG_THREAD,
					.slot = (int8_t)i,
					.holder = (int8_t)s->holder_at_ready,
				};
				log_push(&r);
			}
			s->suspended_ns = 0;
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
			if (!s->has_pthread) {
				s->pthread = pthread_self();
				s->has_pthread = 1;
			}
			probe_holder = i;
		} else if (event & RUBY_INTERNAL_THREAD_EVENT_SUSPENDED) {
			s->suspended_ns = now;
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
 * GVLProbe.start(threads) -> threads: watches up to 6 Threads (replacing
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

// The GC hook: GC_ENTER and GC_EXIT, with the GVL held.  No allocation and
// no Ruby calls (only clock reads, rb_gc_count, and the current thread).
static void log_gc_hook(VALUE tpval, void *data)
{
	(void)data;
	rb_event_flag_t event = rb_tracearg_event_flag(rb_tracearg_from_tracepoint(tpval));
	int64_t now = probe_now();
	if (event & RUBY_INTERNAL_EVENT_GC_ENTER) {
		log_gc_enter_ns = now;
		return;
	}
	if (!(event & RUBY_INTERNAL_EVENT_GC_EXIT) || log_gc_enter_ns == 0) {
		return;
	}

	int64_t ns = now - log_gc_enter_ns;
	log_gc_steps++;
	log_gc_total_ns += ns;
	if (ns > log_gc_max_ns) {
		log_gc_max_ns = ns;
	}
	if (log_on && ns >= log_gc_threshold_ns) {
		VALUE thread = rb_thread_current();
		int slot = -1;
		for (int i = 0; i < probe_slot_count; i++) {
			if (probe_slots[i].thread == thread) {
				slot = i;
				break;
			}
		}
		struct log_record r = {
			.a_ns = log_gc_enter_ns,
			.b_ns = now,
			.gc_count = (int64_t)rb_gc_count(),
			.kind = LOG_GC,
			.slot = (int8_t)slot,
			.holder = -1,
		};
		log_push(&r);
	}
	log_gc_enter_ns = 0;
}

/*
 * GVLProbe.log_start(threshold = 0.001, gc_threshold = 0.0001, size = 65536)
 * -> true: starts the log (see the top): thread records for watched
 * threads off the GVL or waiting for it at least +threshold+ seconds, GC
 * records for steps at least +gc_threshold+ long (nil: no GC hook), in a
 * ring of +size+ records (rounded up to a power of two; allocated once).
 * Keeps logging across GVLProbe.start (records name slots, so drain before
 * watching other threads).
 */
static VALUE probe_log_start(int argc, VALUE *argv, VALUE self)
{
	VALUE threshold, gc_threshold, size;
	rb_scan_args(argc, argv, "03", &threshold, &gc_threshold, &size);

	if (log_ring == NULL) {
		long n = NIL_P(size) ? 65536 : NUM2LONG(size);
		if (n < 16 || n > (1L << 24)) {
			rb_raise(rb_eArgError, "The GVLProbe log holds 16 to 16777216 records (got %ld)", n);
		}
		uint64_t cap = 16;
		while (cap < (uint64_t)n) {
			cap <<= 1;
		}
		log_ring = calloc(cap, sizeof(*log_ring));
		if (log_ring == NULL) {
			rb_raise(rb_eNoMemError, "Could not allocate the GVLProbe log");
		}
		log_cap = cap;
	}

	log_threshold_ns = (int64_t)((NIL_P(threshold) ? 0.001 : NUM2DBL(threshold)) * 1e9);
	if (argc >= 2 && NIL_P(gc_threshold)) {
		if (!NIL_P(log_gc_tracepoint)) {
			rb_tracepoint_disable(log_gc_tracepoint);
		}
	} else {
		log_gc_threshold_ns = (int64_t)((NIL_P(gc_threshold) ? 0.0001 : NUM2DBL(gc_threshold)) * 1e9);
		if (NIL_P(log_gc_tracepoint)) {
			log_gc_tracepoint = rb_tracepoint_new(Qnil, RUBY_INTERNAL_EVENT_GC_ENTER | RUBY_INTERNAL_EVENT_GC_EXIT, log_gc_hook, NULL);
			rb_gc_register_address(&log_gc_tracepoint);
		}
		log_gc_enter_ns = 0;
		rb_tracepoint_enable(log_gc_tracepoint);
	}
	log_on = 1;
	return Qtrue;
}

// GVLProbe.log_stop -> nil: stops logging (and the GC hook); records stay
// for log_drain.
static VALUE probe_log_stop(VALUE self)
{
	log_on = 0;
	if (!NIL_P(log_gc_tracepoint)) {
		rb_tracepoint_disable(log_gc_tracepoint);
	}
	return Qnil;
}

/*
 * GVLProbe.log_drain -> Array of records, oldest first, each
 * [kind, slot, holder, a_ns, b_ns, c_ns, gc_count]: kind :thread (a
 * watched slot off the GVL from a_ns (0: unknown) to b_ns, then waiting
 * until c_ns; holder the slot holding the GVL at b_ns, -1 for none or
 * another thread) or :gc (a GC step from a_ns to b_ns run by watched slot
 * +slot+, -1 another thread; c_ns 0); times CLOCK_MONOTONIC ns; gc_count
 * GC.count after it.
 */
static VALUE probe_log_drain(VALUE self)
{
	VALUE out = rb_ary_new_capa(log_ring ? (long)(log_head - log_tail) : 0);
	if (log_ring == NULL) {
		return out;
	}
	VALUE thread_sym = ID2SYM(rb_intern("thread"));
	VALUE gc_sym = ID2SYM(rb_intern("gc"));
	// (allocating here can run the GC hook, which pushes; take the
	// records first)
	uint64_t head = log_head;
	uint64_t tail = log_tail;
	uint64_t n = head - tail;
	struct log_record *copy = n ? malloc(n * sizeof(*copy)) : NULL;
	if (n && copy == NULL) {
		rb_raise(rb_eNoMemError, "Could not copy the GVLProbe log");
	}
	for (uint64_t k = 0; k < n; k++) {
		copy[k] = log_ring[(tail + k) & (log_cap - 1)];
	}
	log_tail = head;

	for (uint64_t k = 0; k < n; k++) {
		struct log_record *r = &copy[k];
		VALUE row = rb_ary_new_capa(7);
		rb_ary_push(row, r->kind == LOG_GC ? gc_sym : thread_sym);
		rb_ary_push(row, INT2NUM(r->slot));
		rb_ary_push(row, INT2NUM(r->holder));
		rb_ary_push(row, LL2NUM(r->a_ns));
		rb_ary_push(row, LL2NUM(r->b_ns));
		rb_ary_push(row, LL2NUM(r->c_ns));
		rb_ary_push(row, LL2NUM(r->gc_count));
		rb_ary_push(out, row);
	}
	free(copy);
	return out;
}

// GVLProbe.log_stats -> { on:, lost:, gc_steps:, gc_ns:, gc_max_ns: }:
// records overwritten before a drain, and every GC step while the GC hook
// ran (count, total and longest ns).
static VALUE probe_log_stats(VALUE self)
{
	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("on")), log_on ? Qtrue : Qfalse);
	rb_hash_aset(h, ID2SYM(rb_intern("lost")), ULL2NUM(log_lost));
	rb_hash_aset(h, ID2SYM(rb_intern("gc_steps")), ULL2NUM(log_gc_steps));
	rb_hash_aset(h, ID2SYM(rb_intern("gc_ns")), LL2NUM(log_gc_total_ns));
	rb_hash_aset(h, ID2SYM(rb_intern("gc_max_ns")), LL2NUM(log_gc_max_ns));
	return h;
}

// Stacks (see the top).
#define STACK_SAMPLES 512
#define STACK_C 48
#define STACK_RB 32
#define STACK_TEXT 120

struct stack_sample {
	int64_t at_ns;
	int64_t wait_ns;
	int8_t holder;
	int n_c;
	void *c[STACK_C];
	int n_rb;
	int lines[STACK_RB];
	char label[STACK_RB][STACK_TEXT];
	char path[STACK_RB][STACK_TEXT];
};

static struct stack_sample *stack_ring;
static volatile uint64_t stack_head; // written by the handlers
static uint64_t stack_tail;
static uint64_t stack_lost;
static volatile sig_atomic_t stack_request;
static volatile int64_t stack_pending_wait;
static volatile int stack_pending_holder;
static volatile int stack_running;
static int stack_ruby;
static int stack_waiter;
static int64_t stack_threshold_ns;
static int64_t stack_every_ns;
static int stack_signal;
static pthread_t stack_thread;
static int stack_thread_started;
static struct sigaction stack_old_action;

static void stack_copy_text(char *dst, VALUE v)
{
	dst[0] = '\0';
	if (!RB_TYPE_P(v, T_STRING)) {
		return;
	}
	long len = RSTRING_LEN(v);
	if (len > STACK_TEXT - 1) {
		len = STACK_TEXT - 1;
	}
	memcpy(dst, RSTRING_PTR(v), (size_t)len);
	dst[len] = '\0';
}

// The signal handler: runs on the thread holding the GVL.  No allocation.
static void stack_handler(int sig, siginfo_t *info, void *ctx)
{
	(void)sig;
	(void)info;
	(void)ctx;
	int saved = errno;
	if (!stack_request || stack_ring == NULL) {
		errno = saved;
		return;
	}
	stack_request = 0;
	uint64_t i = stack_head;
	if (i - stack_tail >= STACK_SAMPLES) {
		stack_lost++;
		errno = saved;
		return;
	}
	struct stack_sample *s = &stack_ring[i % STACK_SAMPLES];
	s->at_ns = probe_now();
	s->wait_ns = stack_pending_wait;
	s->holder = (int8_t)stack_pending_holder;
	// (the first two frames are this handler and the signal trampoline)
	void *c[STACK_C + 2];
	int n_c = backtrace(c, STACK_C + 2);
	s->n_c = n_c > 2 ? n_c - 2 : 0;
	memcpy(s->c, c + 2, sizeof(void *) * (size_t)s->n_c);
	s->n_rb = 0;
	if (stack_ruby) {
		VALUE frames[STACK_RB];
		int lines[STACK_RB];
		int n = rb_profile_frames(0, STACK_RB, frames, lines);
		for (int k = 0; k < n; k++) {
			s->lines[k] = lines[k];
			stack_copy_text(s->label[k], rb_profile_frame_label(frames[k]));
			if (s->label[k][0] == '\0') {
				stack_copy_text(s->label[k], rb_profile_frame_method_name(frames[k]));
			}
			stack_copy_text(s->path[k], rb_profile_frame_path(frames[k]));
		}
		s->n_rb = n;
	}
	__atomic_store_n(&stack_head, i + 1, __ATOMIC_RELEASE);
	errno = saved;
}

// The watchdog thread (no GVL, no Ruby calls).
static void *stack_watch(void *arg)
{
	(void)arg;
	int64_t last_ready = 0;
	int64_t last_at = 0;
	struct timespec tick = { 0, 1000000 };
	while (stack_running) {
		nanosleep(&tick, NULL);
		if (!probe_hook || stack_waiter >= probe_slot_count) {
			continue;
		}
		int64_t ready = probe_slots[stack_waiter].ready_ns;
		int h = probe_holder;
		if (ready == 0 || h < 0 || h == stack_waiter || h >= probe_slot_count) {
			continue;
		}
		int64_t now = probe_now();
		if (now - ready < stack_threshold_ns) {
			continue;
		}
		if (ready == last_ready && now - last_at < stack_every_ns) {
			continue;
		}
		struct probe_slot *hs = &probe_slots[h];
		if (!hs->has_pthread || stack_request) {
			continue;
		}
		last_ready = ready;
		last_at = now;
		stack_pending_wait = now - ready;
		stack_pending_holder = h;
		stack_request = 1;
		if (pthread_kill(hs->pthread, stack_signal) != 0) {
			stack_request = 0;
		}
	}
	return NULL;
}

/*
 * GVLProbe.stacks_start(threshold = 0.02, waiter = 0, ruby = true, every = threshold)
 * -> true: while watched slot +waiter+ has waited for the GVL at least
 * +threshold+ seconds, records where the watched thread holding it is, at
 * most once every +every+ seconds of one wait (see the top).  Needs
 * GVLProbe.start first (the waiter and holder are watched slots).
 */
static VALUE probe_stacks_start(int argc, VALUE *argv, VALUE self)
{
	VALUE threshold, waiter, ruby, every;
	rb_scan_args(argc, argv, "04", &threshold, &waiter, &ruby, &every);
	if (stack_running) {
		return Qtrue;
	}
	if (stack_ring == NULL) {
		stack_ring = calloc(STACK_SAMPLES, sizeof(*stack_ring));
		if (stack_ring == NULL) {
			rb_raise(rb_eNoMemError, "Could not allocate the GVLProbe stack ring");
		}
	}
	stack_threshold_ns = (int64_t)((NIL_P(threshold) ? 0.02 : NUM2DBL(threshold)) * 1e9);
	stack_every_ns = NIL_P(every) ? stack_threshold_ns : (int64_t)(NUM2DBL(every) * 1e9);
	stack_waiter = NIL_P(waiter) ? 0 : NUM2INT(waiter);
	stack_ruby = NIL_P(ruby) ? 1 : RTEST(ruby);

	// (backtrace's first call loads the unwinder: never in a handler)
	void *warm[4];
	(void)backtrace(warm, 4);

#ifdef SIGRTMIN
	stack_signal = SIGRTMIN + 5;
#else
	stack_signal = SIGPROF;
#endif
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = stack_handler;
	sa.sa_flags = SA_SIGINFO | SA_RESTART;
	sigemptyset(&sa.sa_mask);
	if (sigaction(stack_signal, &sa, &stack_old_action) != 0) {
		rb_sys_fail("GVLProbe.stacks_start: sigaction");
	}

	stack_request = 0;
	stack_running = 1;
	if (pthread_create(&stack_thread, NULL, stack_watch, NULL) != 0) {
		stack_running = 0;
		sigaction(stack_signal, &stack_old_action, NULL);
		rb_raise(rb_eRuntimeError, "GVLProbe.stacks_start: could not start the watchdog thread");
	}
	stack_thread_started = 1;
	return Qtrue;
}

static void *stack_join(void *arg)
{
	(void)arg;
	pthread_join(stack_thread, NULL);
	return NULL;
}

// GVLProbe.stacks_stop -> nil: stops the watchdog (samples stay for
// stacks_drain).
static VALUE probe_stacks_stop(VALUE self)
{
	if (!stack_thread_started) {
		return Qnil;
	}
	stack_running = 0;
	rb_thread_call_without_gvl(stack_join, NULL, RUBY_UBF_IO, NULL);
	stack_thread_started = 0;
	stack_request = 0;
	sigaction(stack_signal, &stack_old_action, NULL);
	return Qnil;
}

// One native frame as text: "symbol+0xoffset (library)" or the address.
static VALUE stack_c_frame(void *addr)
{
	Dl_info info;
	if (dladdr(addr, &info) && info.dli_fname) {
		const char *lib = strrchr(info.dli_fname, '/');
		lib = lib ? lib + 1 : info.dli_fname;
		if (info.dli_sname) {
			return rb_sprintf("%s+0x%lx (%s)", info.dli_sname, (unsigned long)((char *)addr - (char *)info.dli_saddr), lib);
		}
		return rb_sprintf("0x%lx (%s+0x%lx)", (unsigned long)addr, lib, (unsigned long)((char *)addr - (char *)info.dli_fbase));
	}
	return rb_sprintf("0x%lx", (unsigned long)addr);
}

/*
 * GVLProbe.stacks_drain -> Array of Hashes, oldest first: { at_ns:,
 * wait_ns: (the waiter's wait so far), holder: (slot), c: [native frames,
 * innermost first], ruby: ["label path:line", ...] }, and { lost: n } last
 * when samples were dropped (the ring was full).
 */
static VALUE probe_stacks_drain(VALUE self)
{
	VALUE out = rb_ary_new();
	if (stack_ring == NULL) {
		return out;
	}
	uint64_t head = __atomic_load_n(&stack_head, __ATOMIC_ACQUIRE);
	VALUE k_at = ID2SYM(rb_intern("at_ns")), k_wait = ID2SYM(rb_intern("wait_ns")), k_holder = ID2SYM(rb_intern("holder"));
	VALUE k_c = ID2SYM(rb_intern("c")), k_ruby = ID2SYM(rb_intern("ruby"));
	for (uint64_t i = stack_tail; i < head; i++) {
		struct stack_sample *s = &stack_ring[i % STACK_SAMPLES];
		VALUE h = rb_hash_new();
		rb_hash_aset(h, k_at, LL2NUM(s->at_ns));
		rb_hash_aset(h, k_wait, LL2NUM(s->wait_ns));
		rb_hash_aset(h, k_holder, INT2NUM(s->holder));
		VALUE c = rb_ary_new_capa(s->n_c);
		for (int k = 0; k < s->n_c; k++) {
			rb_ary_push(c, stack_c_frame(s->c[k]));
		}
		rb_hash_aset(h, k_c, c);
		VALUE r = rb_ary_new_capa(s->n_rb);
		for (int k = 0; k < s->n_rb; k++) {
			rb_ary_push(r, rb_sprintf("%s %s:%d", s->label[k], s->path[k], s->lines[k]));
		}
		rb_hash_aset(h, k_ruby, r);
		rb_ary_push(out, h);
	}
	stack_tail = head;
	if (stack_lost) {
		VALUE h = rb_hash_new();
		rb_hash_aset(h, ID2SYM(rb_intern("lost")), ULL2NUM(stack_lost));
		stack_lost = 0;
		rb_ary_push(out, h);
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
	rb_define_module_function(mProbe, "log_start", probe_log_start, -1);
	rb_define_module_function(mProbe, "log_stop", probe_log_stop, 0);
	rb_define_module_function(mProbe, "log_drain", probe_log_drain, 0);
	rb_define_module_function(mProbe, "log_stats", probe_log_stats, 0);
	rb_define_module_function(mProbe, "stacks_start", probe_stacks_start, -1);
	rb_define_module_function(mProbe, "stacks_stop", probe_stacks_stop, 0);
	rb_define_module_function(mProbe, "stacks_drain", probe_stacks_drain, 0);
}
