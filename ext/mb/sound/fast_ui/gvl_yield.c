/*
 * MB::Sound::FastUI::GVLYield: background threads that give the GVL to a
 * priority thread (the Session's render thread) as soon as it wants it
 * (ui-wave-perf-1 round 3; design/notes/sound_design_ui.md, "The workers
 * yield").
 *
 * Ruby moves the GVL from a running thread to a waiting one only at the
 * timer's interrupt (RUBY_THREAD_TIMESLICE, 10 ms in mb-sound's shebang)
 * or when the running thread blocks or calls Thread.pass.  A preview worker
 * building a copy of a voice runs Ruby for 10-30 ms without blocking, so
 * the render thread, woken for its next buffer, waited up to a timeslice.
 *
 * Here a Ruby internal thread event hook (ruby/thread.h) watches the
 * priority thread and the registered yielder threads.  When the priority
 * thread becomes READY (wants the GVL) while a yielder holds it, a kicker
 * pthread (not a Ruby thread) triggers a postponed job; Ruby runs the job
 * on the thread holding the GVL at its next interrupt check (a method
 * return or loop branch: microseconds in Ruby code), and the job, if that
 * thread is a yielder and the priority thread still waits, calls
 * rb_thread_schedule(), which hands the GVL over (the same switch the
 * timer makes, only sooner).  The trigger comes from the kicker because
 * rb_postponed_job_trigger marks the calling thread's execution context
 * when it has one: from the hook it would mark the waiting render thread
 * itself.  While the priority thread still waits the kicker triggers again
 * every KICK_RETRY_NS (a long C call has no interrupt check until it
 * returns; a job run before the waiter queued switches nothing).
 *
 * Scheduling, not computation: no Ruby mirror (Kernels::UNMIRRORED).  The
 * hook and kicker run only while a priority thread is set and at least
 * one yielder is registered.  The thread table is written with the GVL
 * held and read by the hook and kicker with atomic loads.  A forked child
 * turns everything off (its kicker thread doesn't exist there).
 */
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>

#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/debug.h>

#define YIELD_SLOTS 8
#define KICK_RETRY_NS 200000
#define KICK_RETRIES 50

static VALUE yield_priority = Qnil;
static VALUE yield_threads[YIELD_SLOTS]; // Qnil (0 never used: Qfalse) when empty

static int priority_waiting; // the priority thread is READY, not yet RESUMED
static int yielder_holds; // a yielder holds the GVL (RESUMED, not yet SUSPENDED)
static int kicker_running;
static int forked_child;

static uint64_t stat_kicks;
static uint64_t stat_yields;
static uint64_t stat_retries;
static uint64_t stat_wakeups;
static int64_t kick_ns; // when the current wait's first kick was triggered (0: none)
static uint64_t stat_late1; // handovers more than 1 ms after their first kick
static uint64_t stat_late2; // ... more than 2 ms
static int64_t stat_late_max_ns;

static sem_t kick_sem;
static pthread_t kick_thread;
static rb_postponed_job_handle_t yield_job_handle = POSTPONED_JOB_HANDLE_INVALID;
static rb_internal_thread_event_hook_t *yield_hook;

#define LOAD(x) __atomic_load_n(&(x), __ATOMIC_ACQUIRE)
#define STORE(x, v) __atomic_store_n(&(x), (v), __ATOMIC_RELEASE)
#define ADD(x, v) __atomic_fetch_add(&(x), (v), __ATOMIC_RELAXED)

static int yield_is_yielder(VALUE thread)
{
	for (int i = 0; i < YIELD_SLOTS; i++) {
		if (LOAD(yield_threads[i]) == thread) {
			return 1;
		}
	}
	return 0;
}

// The postponed job (GVL held, at an interrupt check of the running thread).
static void yield_job(void *data)
{
	if (!LOAD(priority_waiting) || !yield_is_yielder(rb_thread_current())) {
		return;
	}
	ADD(stat_yields, 1);
	int64_t k = LOAD(kick_ns);
	if (k) {
		// (how long the holder ran on after the first kick: a long C call
		// or a GC step checks no interrupts)
		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		int64_t late = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec - k;
		if (late > 1000000) {
			ADD(stat_late1, 1);
		}
		if (late > 2000000) {
			ADD(stat_late2, 1);
		}
		if (late > LOAD(stat_late_max_ns)) {
			STORE(stat_late_max_ns, late);
		}
		STORE(kick_ns, 0);
	}
	rb_thread_schedule();
}

static void *yield_kicker(void *arg)
{
	struct timespec retry = { 0, KICK_RETRY_NS };
	while (1) {
		while (sem_wait(&kick_sem) != 0 && errno == EINTR) {
		}
		ADD(stat_wakeups, 1);
		if (!LOAD(kicker_running)) {
			break;
		}
		for (int k = 0; k < KICK_RETRIES && LOAD(kicker_running) && LOAD(priority_waiting) && LOAD(yielder_holds); k++) {
			if (k == 0) {
				ADD(stat_kicks, 1);
				struct timespec ts;
				clock_gettime(CLOCK_MONOTONIC, &ts);
				STORE(kick_ns, (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec);
			} else {
				ADD(stat_retries, 1);
			}
			rb_postponed_job_trigger(yield_job_handle);
			nanosleep(&retry, NULL);
		}
	}
	return NULL;
}

// The event hook (on the thread with the event, without the GVL).
static void yield_event(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data)
{
	if (LOAD(forked_child)) {
		return;
	}
	VALUE thread = data->thread;
	if (thread == LOAD(yield_priority)) {
		if (event & RUBY_INTERNAL_THREAD_EVENT_READY) {
			STORE(priority_waiting, 1);
			if (LOAD(yielder_holds)) {
				sem_post(&kick_sem);
			}
		} else if (event & RUBY_INTERNAL_THREAD_EVENT_RESUMED) {
			STORE(priority_waiting, 0);
		}
		return;
	}
	if (!yield_is_yielder(thread)) {
		return;
	}
	if (event & RUBY_INTERNAL_THREAD_EVENT_EXITED) {
		// (a yielder that ends leaves the table; its slot is written by
		// no one else while it holds the thread's VALUE)
		for (int i = 0; i < YIELD_SLOTS; i++) {
			if (LOAD(yield_threads[i]) == thread) {
				STORE(yield_threads[i], Qnil);
			}
		}
		STORE(yielder_holds, 0);
		return;
	}
	if (event & RUBY_INTERNAL_THREAD_EVENT_RESUMED) {
		STORE(yielder_holds, 1);
		if (LOAD(priority_waiting)) {
			sem_post(&kick_sem);
		}
	} else if (event & RUBY_INTERNAL_THREAD_EVENT_SUSPENDED) {
		STORE(yielder_holds, 0);
	}
}

static void yield_atfork_child(void)
{
	forked_child = 1;
	kicker_running = 0;
}

static int yield_count(void)
{
	int n = 0;
	for (int i = 0; i < YIELD_SLOTS; i++) {
		n += yield_threads[i] != Qnil;
	}
	return n;
}

// Starts or stops the hook and kicker to match the table (GVL held).
static void yield_update(void)
{
	int want = !NIL_P(yield_priority) && yield_count() > 0 && !forked_child;
	if (want && !kicker_running) {
		STORE(priority_waiting, 0);
		STORE(yielder_holds, 0);
		STORE(kicker_running, 1);
		if (pthread_create(&kick_thread, NULL, yield_kicker, NULL) != 0) {
			STORE(kicker_running, 0);
			rb_raise(rb_eRuntimeError, "GVLYield: could not start the kicker thread");
		}
		yield_hook = rb_internal_thread_add_event_hook(yield_event,
				RUBY_INTERNAL_THREAD_EVENT_READY | RUBY_INTERNAL_THREAD_EVENT_RESUMED | RUBY_INTERNAL_THREAD_EVENT_SUSPENDED |
				RUBY_INTERNAL_THREAD_EVENT_EXITED, NULL);
	} else if (!want && kicker_running) {
		rb_internal_thread_remove_event_hook(yield_hook);
		yield_hook = NULL;
		STORE(kicker_running, 0);
		sem_post(&kick_sem);
		pthread_join(kick_thread, NULL);
		STORE(priority_waiting, 0);
		STORE(yielder_holds, 0);
	}
}

static void yield_check_thread(VALUE thread)
{
	if (!rb_obj_is_kind_of(thread, rb_cThread)) {
		rb_raise(rb_eTypeError, "GVLYield: expected a Thread, got %"PRIsVALUE, rb_obj_class(thread));
	}
}

// GVLYield.priority = thread (or nil): the thread the yielders give the GVL to.
static VALUE yield_set_priority(VALUE self, VALUE thread)
{
	if (forked_child) {
		return Qnil;
	}
	if (!NIL_P(thread)) {
		yield_check_thread(thread);
	}
	STORE(yield_priority, thread);
	yield_update();
	return thread;
}

static VALUE yield_get_priority(VALUE self)
{
	return yield_priority;
}

// GVLYield.add(thread) -> true, or false when the table is full (or in a
// forked child): +thread+ gives the GVL to the priority thread whenever
// that wants it.
static VALUE yield_add(VALUE self, VALUE thread)
{
	yield_check_thread(thread);
	if (forked_child) {
		return Qfalse;
	}
	if (yield_is_yielder(thread)) {
		return Qtrue;
	}
	for (int i = 0; i < YIELD_SLOTS; i++) {
		if (yield_threads[i] == Qnil) {
			STORE(yield_threads[i], thread);
					yield_update();
			return Qtrue;
		}
	}
	return Qfalse;
}

// GVLYield.remove(thread) -> true if it was a yielder.
static VALUE yield_remove(VALUE self, VALUE thread)
{
	int found = 0;
	for (int i = 0; i < YIELD_SLOTS; i++) {
		if (yield_threads[i] == thread) {
			STORE(yield_threads[i], Qnil);
			found = 1;
		}
	}
	if (found) {
			yield_update();
	}
	return found ? Qtrue : Qfalse;
}

// GVLYield.yielders -> Array of the registered threads.
static VALUE yield_yielders(VALUE self)
{
	VALUE out = rb_ary_new();
	for (int i = 0; i < YIELD_SLOTS; i++) {
		if (yield_threads[i] != Qnil) {
			rb_ary_push(out, yield_threads[i]);
		}
	}
	return out;
}

static VALUE yield_active(VALUE self)
{
	return kicker_running ? Qtrue : Qfalse;
}

// GVLYield.stats -> { kicks:, retries:, yields:, wakeups:, late_1ms:,
// late_2ms:, late_max_ns: } since the
// process started: times the priority thread waited on a yielder (a kick),
// kicks repeated while it still waited, handovers made, times the kicker
// thread woke (it sleeps on a semaphore otherwise), and handovers that came
// more than 1 and 2 ms after their first kick, with the longest (ns): the
// holder was in a C call or a GC step, which check no interrupts.
static VALUE yield_stats(VALUE self)
{
	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("kicks")), ULL2NUM(LOAD(stat_kicks)));
	rb_hash_aset(h, ID2SYM(rb_intern("retries")), ULL2NUM(LOAD(stat_retries)));
	rb_hash_aset(h, ID2SYM(rb_intern("yields")), ULL2NUM(LOAD(stat_yields)));
	rb_hash_aset(h, ID2SYM(rb_intern("wakeups")), ULL2NUM(LOAD(stat_wakeups)));
	rb_hash_aset(h, ID2SYM(rb_intern("late_1ms")), ULL2NUM(LOAD(stat_late1)));
	rb_hash_aset(h, ID2SYM(rb_intern("late_2ms")), ULL2NUM(LOAD(stat_late2)));
	rb_hash_aset(h, ID2SYM(rb_intern("late_max_ns")), LL2NUM(LOAD(stat_late_max_ns)));
	return h;
}

void mb_fast_ui_init_gvl_yield(VALUE mFastUI)
{
	for (int i = 0; i < YIELD_SLOTS; i++) {
		yield_threads[i] = Qnil;
	}
	// (global addresses are marked conservatively, so the threads stay
	// alive and are never moved by compaction: the hook compares VALUEs)
	rb_gc_register_address(&yield_priority);
	for (int i = 0; i < YIELD_SLOTS; i++) {
		rb_gc_register_address(&yield_threads[i]);
	}
	if (sem_init(&kick_sem, 0, 0) != 0) {
		rb_raise(rb_eRuntimeError, "GVLYield: sem_init failed");
	}
	yield_job_handle = rb_postponed_job_preregister(0, yield_job, NULL);
	if (yield_job_handle == POSTPONED_JOB_HANDLE_INVALID) {
		rb_raise(rb_eRuntimeError, "GVLYield: no postponed job handle");
	}
	pthread_atfork(NULL, NULL, yield_atfork_child);

	VALUE mYield = rb_define_module_under(mFastUI, "GVLYield");
	rb_define_module_function(mYield, "priority=", yield_set_priority, 1);
	rb_define_module_function(mYield, "priority", yield_get_priority, 0);
	rb_define_module_function(mYield, "add", yield_add, 1);
	rb_define_module_function(mYield, "remove", yield_remove, 1);
	rb_define_module_function(mYield, "yielders", yield_yielders, 0);
	rb_define_module_function(mYield, "active?", yield_active, 0);
	rb_define_module_function(mYield, "stats", yield_stats, 0);
}
