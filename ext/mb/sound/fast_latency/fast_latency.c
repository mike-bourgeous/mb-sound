/*
 * MB::Sound::FastLatency: a system latency probe that never touches Ruby
 * (latency-probe-1, 2026-10-25).
 *
 * A pthread wakes on an absolute-deadline loop (clock_nanosleep with
 * TIMER_ABSTIME on Linux, mach_wait_until on macOS), records how late each
 * wake was, and optionally times a little fixed work each tick: a walk of
 * part of a buffer larger than the caches (read-modify-write, one byte per
 * 64-byte line) and a CPU-only integer loop.  scene-jit-1 found that the
 * Mac's Docker VM slows memory-touching work ~10x at the top of every
 * minute while CPU-only work runs normally, so the two are timed apart.
 *
 * Every tick feeds per-second aggregates (by CLOCK_REALTIME second: count,
 * max, p50/p99 from log-bucket histograms, thread CPU time, context
 * switches, CPU migrations) and lifetime log-bucket histograms.  Ticks over
 * the threshold become tick events (capped per second) and are merged into
 * stall episodes.  Seconds, events, and episodes go through a lock-free
 * single-producer single-consumer ring; when it is full the record is
 * dropped and counted, so the probe never blocks.  The probe only signals
 * the consumer through pthread_mutex_trylock, which never blocks either.
 *
 * The consumer is a Ruby thread blocked in Probe#wait with the GVL released
 * (rb_thread_call_without_gvl on a condition variable), which then drains
 * the ring into Ruby Hashes with Probe#drain.  A plain C thread can't create
 * Ruby objects, so this is how "another C thread pulls the data into Ruby"
 * is done safely.
 *
 * Histogram buckets (mirror: MB::Sound::LatencyProbe::Histogram.bucket):
 * values under 16 ns have a bucket each; above, 16 buckets per power of
 * two (~4.4% wide) up to 2^41 ns (~37 minutes), the last bucket holding
 * everything larger.
 */

#if !defined(__APPLE__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif

#include <ruby.h>
#include <ruby/thread.h>

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/time.h>

#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#else
#include <sched.h>
#include <sys/syscall.h>
#endif

#define MB_LAT_SUB_BITS 4
#define MB_LAT_SUB (1 << MB_LAT_SUB_BITS)
#define MB_LAT_MAX_EXP 40
#define MB_LAT_BUCKETS ((MB_LAT_MAX_EXP - MB_LAT_SUB_BITS + 2) * MB_LAT_SUB)

#define MB_LAT_HISTS 4 // late, mem, cpu, stall
#define MB_LAT_SECOND_HISTS 3 // late, mem, cpu

#define MB_LAT_CALIBRATION 256

#define MB_LAT_KIND_SECOND 1
#define MB_LAT_KIND_EPISODE 2
#define MB_LAT_KIND_TICK 3

#define MB_LAT_EPISODE_MAX_NS 10000000000LL

static inline int mb_lat_bucket(int64_t v)
{
	if (v < 0) {
		v = 0;
	}
	if (v < MB_LAT_SUB) {
		return (int)v;
	}

	int e = 63 - __builtin_clzll((unsigned long long)v);
	if (e > MB_LAT_MAX_EXP) {
		return MB_LAT_BUCKETS - 1;
	}

	int m = (int)((v >> (e - MB_LAT_SUB_BITS)) & (MB_LAT_SUB - 1));
	return (e - MB_LAT_SUB_BITS + 1) * MB_LAT_SUB + m;
}

static inline int64_t mb_lat_bucket_floor(int i)
{
	if (i < MB_LAT_SUB) {
		return i;
	}
	int e = (i >> MB_LAT_SUB_BITS) + MB_LAT_SUB_BITS - 1;
	int m = i & (MB_LAT_SUB - 1);
	return (int64_t)(MB_LAT_SUB + m) << (e - MB_LAT_SUB_BITS);
}

static inline int64_t mb_lat_bucket_width(int i)
{
	if (i < MB_LAT_SUB) {
		return 1;
	}
	int e = (i >> MB_LAT_SUB_BITS) + MB_LAT_SUB_BITS - 1;
	return (int64_t)1 << (e - MB_LAT_SUB_BITS);
}

// A bucket's representative value: its middle (exact below 16 ns).
static inline int64_t mb_lat_bucket_value(int i)
{
	return mb_lat_bucket_floor(i) + (mb_lat_bucket_width(i) - 1) / 2;
}

// The value at quantile q (0..1) of a histogram: the first bucket whose
// running count reaches ceil(q * total) (at least 1), as its middle value;
// 0 for an empty histogram.
static int64_t mb_lat_percentile_u32(const uint32_t *counts, double q)
{
	uint64_t total = 0;
	for (int i = 0; i < MB_LAT_BUCKETS; i++) {
		total += counts[i];
	}
	if (total == 0) {
		return 0;
	}

	double t = q * (double)total;
	uint64_t target = (uint64_t)t;
	if ((double)target < t) {
		target++;
	}
	if (target < 1) {
		target = 1;
	}

	uint64_t sum = 0;
	for (int i = 0; i < MB_LAT_BUCKETS; i++) {
		sum += counts[i];
		if (sum >= target) {
			return mb_lat_bucket_value(i);
		}
	}
	return mb_lat_bucket_value(MB_LAT_BUCKETS - 1);
}

typedef struct {
	int32_t kind;
	int32_t cpu;
	int64_t wall_ns;
	int64_t mono_ns;
	int64_t end_mono_ns;
	int64_t worst_wall_ns;
	int64_t late_ns;
	int64_t mem_ns;
	int64_t cpu_ns;
	int64_t tcpu_ns;
	int64_t stall_ns;
	int64_t ticks;
	int64_t missed;
	int64_t over;
	int64_t events;
	int64_t dropped;
	int64_t late_p50;
	int64_t late_p99;
	int64_t late_sum;
	int64_t mem_p50;
	int64_t mem_p99;
	int64_t cpu_p50;
	int64_t cpu_p99;
	int64_t nivcsw;
	int64_t nvcsw;
	int64_t migrations;
} mb_lat_record;

typedef struct {
	// Settings (fixed once started)
	int64_t period_ns;
	int64_t threshold_ns;
	int64_t gap_ns;
	double work_ratio;
	int64_t work_min_ns;
	size_t mem_bytes;
	size_t mem_touch;
	int64_t cpu_iterations;
	int64_t events_per_second;
	int rt_priority; // SCHED_FIFO priority to try on Linux; 0 skips realtime
	int nice; // nice value to try on Linux when realtime fails (0 skips)
	int boost; // 0: leave the thread's priority alone
	int pin_cpu; // -1: no pinning
	int want_mlock;

	// Thread
	pthread_t thread;
	int started;
	pid_t pid;
	atomic_int stop;
	atomic_int running;

	// Work buffers
	uint8_t *mem;
	size_t mem_pos;
	uint64_t cpu_state;

	// Ring (single producer: the probe; single consumer: #drain)
	mb_lat_record *ring;
	uint64_t ring_cap;
	_Atomic uint64_t head;
	_Atomic uint64_t tail;
	_Atomic uint64_t overflow;
	pthread_mutex_t mu;
	pthread_cond_t cond;
	int interrupt; // set by the unblock function, under mu

	// Lifetime counters (written by the probe, read anywhere)
	_Atomic uint64_t hist[MB_LAT_HISTS][MB_LAT_BUCKETS];
	_Atomic uint64_t ticks;
	_Atomic uint64_t missed;
	_Atomic uint64_t over;
	_Atomic uint64_t events;
	_Atomic uint64_t episodes;
	_Atomic uint64_t dropped;
	_Atomic int64_t max_late;
	_Atomic int64_t max_stall;
	_Atomic int64_t mem_base;
	_Atomic int64_t cpu_base;
	atomic_int calibrated;
	atomic_int last_cpu;
	_Atomic int64_t start_mono;
	_Atomic int64_t start_wall;

	// Calibration (probe thread only)
	int calib_n;
	int64_t calib_mem[MB_LAT_CALIBRATION];
	int64_t calib_cpu[MB_LAT_CALIBRATION];

	// Per-second aggregates (probe thread only)
	int64_t sec;
	uint32_t sh[MB_LAT_SECOND_HISTS][MB_LAT_BUCKETS];
	mb_lat_record cur;
	int64_t sec_tcpu0;
	int64_t sec_nivcsw0;
	int64_t sec_nvcsw0;

	// The open stall episode (probe thread only)
	int ep_open;
	int64_t ep_last_over;
	mb_lat_record ep;

	// Results of setting up the thread, written before running is set
	char priority[160];
	int mlocked;
	char error[160];
} mb_lat_probe;

/* Clocks */

#ifdef __APPLE__
static mach_timebase_info_data_t mb_lat_timebase;

static inline int64_t mb_lat_abs_to_ns(uint64_t abs)
{
	return (int64_t)((abs / mb_lat_timebase.denom) * mb_lat_timebase.numer +
			(abs % mb_lat_timebase.denom) * mb_lat_timebase.numer / mb_lat_timebase.denom);
}

static inline uint64_t mb_lat_ns_to_abs(int64_t ns)
{
	uint64_t n = (uint64_t)ns;
	return (n / mb_lat_timebase.numer) * mb_lat_timebase.denom +
		(n % mb_lat_timebase.numer) * mb_lat_timebase.denom / mb_lat_timebase.numer;
}

static inline int64_t mb_lat_mono_ns(void)
{
	return mb_lat_abs_to_ns(mach_absolute_time());
}

static inline void mb_lat_sleep_until(int64_t ns)
{
	mach_wait_until(mb_lat_ns_to_abs(ns));
}
#else
static inline int64_t mb_lat_mono_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static inline void mb_lat_sleep_until(int64_t ns)
{
	struct timespec ts = { .tv_sec = ns / 1000000000LL, .tv_nsec = ns % 1000000000LL };
	while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
	}
}
#endif

static inline int64_t mb_lat_wall_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static inline int64_t mb_lat_thread_cpu_ns(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
		return -1;
	}
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static inline int mb_lat_current_cpu(void)
{
#ifdef __APPLE__
	return -1;
#else
	return sched_getcpu();
#endif
}

// Voluntary and involuntary context switches of the calling thread, or -1
// where unavailable (macOS).
static void mb_lat_switches(int64_t *voluntary, int64_t *involuntary)
{
#if defined(RUSAGE_THREAD)
	struct rusage ru;
	if (getrusage(RUSAGE_THREAD, &ru) == 0) {
		*voluntary = ru.ru_nvcsw;
		*involuntary = ru.ru_nivcsw;
		return;
	}
#endif
	*voluntary = -1;
	*involuntary = -1;
}

/* Priority */

static void mb_lat_set_priority(mb_lat_probe *p)
{
	if (!p->boost) {
		snprintf(p->priority, sizeof(p->priority), "normal (not requested)");
		return;
	}

#ifdef __APPLE__
	thread_time_constraint_policy_data_t pol;
	int64_t computation = p->period_ns / 2;
	if (computation > 50000000LL) {
		computation = 50000000LL;
	}
	pol.period = (uint32_t)mb_lat_ns_to_abs(p->period_ns);
	pol.computation = (uint32_t)mb_lat_ns_to_abs(computation);
	pol.constraint = (uint32_t)mb_lat_ns_to_abs(p->period_ns);
	pol.preemptible = 1;
	kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
			(thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
	if (kr == KERN_SUCCESS) {
		snprintf(p->priority, sizeof(p->priority), "time constraint (period %lld us, computation %lld us)",
				(long long)(p->period_ns / 1000), (long long)(computation / 1000));
		return;
	}
	if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0) {
		snprintf(p->priority, sizeof(p->priority), "QoS user-interactive (time constraint failed: %d)", (int)kr);
		return;
	}
	snprintf(p->priority, sizeof(p->priority), "normal (time constraint failed: %d)", (int)kr);
#else
	char why[96] = "";
	if (p->rt_priority > 0) {
		struct sched_param sp = { .sched_priority = p->rt_priority };
		int r = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
		if (r == 0) {
			snprintf(p->priority, sizeof(p->priority), "SCHED_FIFO %d", p->rt_priority);
			return;
		}
		snprintf(why, sizeof(why), "SCHED_FIFO %d: %s", p->rt_priority, strerror(r));
	}
	if (p->nice != 0) {
		pid_t tid = (pid_t)syscall(SYS_gettid);
		if (setpriority(PRIO_PROCESS, (id_t)tid, p->nice) == 0) {
			snprintf(p->priority, sizeof(p->priority), "nice %d (%s)", p->nice, why[0] ? why : "realtime not tried");
			return;
		}
		int e = errno;
		snprintf(p->priority, sizeof(p->priority), "normal (%s%snice %d: %s)", why, why[0] ? "; " : "", p->nice, strerror(e));
		return;
	}
	snprintf(p->priority, sizeof(p->priority), "normal (%s)", why[0] ? why : "nothing tried");
#endif
}

static void mb_lat_pin(mb_lat_probe *p)
{
	if (p->pin_cpu < 0) {
		return;
	}
#ifdef __APPLE__
	snprintf(p->error, sizeof(p->error), "CPU pinning isn't available on macOS");
#else
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(p->pin_cpu, &set);
	int r = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
	if (r != 0) {
		snprintf(p->error, sizeof(p->error), "pinning to CPU %d: %s", p->pin_cpu, strerror(r));
	}
#endif
}

/* Ring */

// Pushes a record, or counts it as overflow when the ring is full.  Never
// blocks.  Wakes the consumer (without waiting for its mutex) if +wake+.
static void mb_lat_push(mb_lat_probe *p, const mb_lat_record *r, int wake)
{
	uint64_t head = atomic_load_explicit(&p->head, memory_order_relaxed);
	uint64_t tail = atomic_load_explicit(&p->tail, memory_order_acquire);
	if (head - tail >= p->ring_cap) {
		atomic_fetch_add_explicit(&p->overflow, 1, memory_order_relaxed);
		return;
	}

	p->ring[head & (p->ring_cap - 1)] = *r;
	atomic_store_explicit(&p->head, head + 1, memory_order_release);

	if (wake || head + 1 - tail > p->ring_cap / 2) {
		if (pthread_mutex_trylock(&p->mu) == 0) {
			pthread_cond_signal(&p->cond);
			pthread_mutex_unlock(&p->mu);
		}
	}
}

static inline void mb_lat_count(_Atomic uint64_t *c, uint64_t n)
{
	atomic_fetch_add_explicit(c, n, memory_order_relaxed);
}

static inline void mb_lat_max(_Atomic int64_t *m, int64_t v)
{
	if (v > atomic_load_explicit(m, memory_order_relaxed)) {
		atomic_store_explicit(m, v, memory_order_relaxed);
	}
}

/* Per-second aggregates */

static void mb_lat_second_begin(mb_lat_probe *p, int64_t sec)
{
	p->sec = sec;
	memset(p->sh, 0, sizeof(p->sh));
	memset(&p->cur, 0, sizeof(p->cur));
	p->cur.kind = MB_LAT_KIND_SECOND;
	p->cur.wall_ns = sec * 1000000000LL;
	p->cur.cpu = -1;
	p->sec_tcpu0 = mb_lat_thread_cpu_ns();
	mb_lat_switches(&p->sec_nvcsw0, &p->sec_nivcsw0);
}

static void mb_lat_second_end(mb_lat_probe *p)
{
	mb_lat_record *c = &p->cur;
	c->late_p50 = mb_lat_percentile_u32(p->sh[0], 0.5);
	c->late_p99 = mb_lat_percentile_u32(p->sh[0], 0.99);
	c->mem_p50 = mb_lat_percentile_u32(p->sh[1], 0.5);
	c->mem_p99 = mb_lat_percentile_u32(p->sh[1], 0.99);
	c->cpu_p50 = mb_lat_percentile_u32(p->sh[2], 0.5);
	c->cpu_p99 = mb_lat_percentile_u32(p->sh[2], 0.99);

	int64_t tcpu = mb_lat_thread_cpu_ns();
	c->tcpu_ns = (tcpu >= 0 && p->sec_tcpu0 >= 0) ? tcpu - p->sec_tcpu0 : -1;

	int64_t v, iv;
	mb_lat_switches(&v, &iv);
	c->nvcsw = v >= 0 ? v - p->sec_nvcsw0 : -1;
	c->nivcsw = iv >= 0 ? iv - p->sec_nivcsw0 : -1;

	mb_lat_push(p, c, 1);
}

/* Episodes */

static void mb_lat_episode_close(mb_lat_probe *p)
{
	if (!p->ep_open) {
		return;
	}
	p->ep_open = 0;
	mb_lat_count(&p->episodes, 1);
	mb_lat_push(p, &p->ep, 1);
}

/* Work */

static int64_t mb_lat_touch_memory(mb_lat_probe *p)
{
	volatile uint8_t *m = p->mem;
	size_t pos = p->mem_pos;
	size_t end = pos + p->mem_touch;
	uint64_t sum = 0;

	for (; pos < end; pos += 64) {
		size_t i = pos % p->mem_bytes;
		uint8_t b = m[i];
		sum += b;
		m[i] = (uint8_t)(b + 1);
	}

	p->mem_pos = end % p->mem_bytes;
	return (int64_t)sum;
}

static uint64_t mb_lat_spin_cpu(uint64_t x, int64_t n)
{
	for (int64_t i = 0; i < n; i++) {
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
	}
	return x;
}

static int mb_lat_cmp64(const void *a, const void *b)
{
	int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
	return (x > y) - (x < y);
}

static volatile int64_t mb_lat_sink;

/* The probe thread */

static void *mb_lat_probe_main(void *arg)
{
	mb_lat_probe *p = arg;

	mb_lat_pin(p);
	mb_lat_set_priority(p);

	int64_t start = mb_lat_mono_ns();
	int64_t wall0 = mb_lat_wall_ns();
	atomic_store(&p->start_mono, start);
	atomic_store(&p->start_wall, wall0);
	mb_lat_second_begin(p, wall0 / 1000000000LL);
	int last_cpu = mb_lat_current_cpu();
	atomic_store(&p->last_cpu, last_cpu);
	atomic_store(&p->running, 1);

	int64_t next = start + p->period_ns;

	while (!atomic_load_explicit(&p->stop, memory_order_relaxed)) {
		mb_lat_sleep_until(next);

		int64_t wake = mb_lat_mono_ns();
		int64_t wall = mb_lat_wall_ns();
		int64_t late = wake - next;
		if (late < 0) {
			late = 0;
		}

		int64_t mem_ns = 0, tcpu_ns = 0, cpu_ns = 0;
		if (p->mem != NULL) {
			int64_t tc0 = mb_lat_thread_cpu_ns();
			int64_t a = mb_lat_mono_ns();
			mb_lat_sink += mb_lat_touch_memory(p);
			int64_t b = mb_lat_mono_ns();
			int64_t tc1 = mb_lat_thread_cpu_ns();
			mem_ns = b - a;
			tcpu_ns = (tc0 >= 0 && tc1 >= 0) ? tc1 - tc0 : -1;
		}
		if (p->cpu_iterations > 0) {
			int64_t a = mb_lat_mono_ns();
			p->cpu_state = mb_lat_spin_cpu(p->cpu_state, p->cpu_iterations);
			cpu_ns = mb_lat_mono_ns() - a;
		}
		int64_t done = mb_lat_mono_ns();

		int cpu = mb_lat_current_cpu();

		// A new wall-clock second closes the last one (seconds with no tick
		// at all, inside a long stall, are left for the consumer to fill)
		int64_t sec = wall / 1000000000LL;
		if (sec != p->sec) {
			mb_lat_second_end(p);
			mb_lat_second_begin(p, sec);
		}

		// Baselines for the work probes: medians of the first ticks
		int calibrated = atomic_load_explicit(&p->calibrated, memory_order_relaxed);
		if (!calibrated && (p->mem != NULL || p->cpu_iterations > 0)) {
			p->calib_mem[p->calib_n] = mem_ns;
			p->calib_cpu[p->calib_n] = cpu_ns;
			p->calib_n++;
			if (p->calib_n == MB_LAT_CALIBRATION) {
				qsort(p->calib_mem, MB_LAT_CALIBRATION, sizeof(int64_t), mb_lat_cmp64);
				qsort(p->calib_cpu, MB_LAT_CALIBRATION, sizeof(int64_t), mb_lat_cmp64);
				atomic_store(&p->mem_base, p->calib_mem[MB_LAT_CALIBRATION / 2]);
				atomic_store(&p->cpu_base, p->calib_cpu[MB_LAT_CALIBRATION / 2]);
				atomic_store(&p->calibrated, 1);
				calibrated = 1;
			}
		}

		// The stall: wake lateness, or how much longer the work took than
		// its baseline, whichever is more
		int64_t stall = late;
		int over = late > p->threshold_ns;
		if (calibrated) {
			int64_t mb = atomic_load_explicit(&p->mem_base, memory_order_relaxed);
			int64_t cb = atomic_load_explicit(&p->cpu_base, memory_order_relaxed);
			if (p->mem != NULL) {
				int64_t ex = mem_ns - mb;
				if (ex > stall) {
					stall = ex;
				}
				if (ex > p->threshold_ns || (mem_ns > p->work_ratio * mb && ex > p->work_min_ns)) {
					over = 1;
				}
			}
			if (p->cpu_iterations > 0) {
				int64_t ex = cpu_ns - cb;
				if (ex > stall) {
					stall = ex;
				}
				if (ex > p->threshold_ns || (cpu_ns > p->work_ratio * cb && ex > p->work_min_ns)) {
					over = 1;
				}
			}
		}

		// Lifetime histograms and counters
		mb_lat_count(&p->hist[0][mb_lat_bucket(late)], 1);
		if (p->mem != NULL) {
			mb_lat_count(&p->hist[1][mb_lat_bucket(mem_ns)], 1);
		}
		if (p->cpu_iterations > 0) {
			mb_lat_count(&p->hist[2][mb_lat_bucket(cpu_ns)], 1);
		}
		mb_lat_count(&p->hist[3][mb_lat_bucket(stall)], 1);
		mb_lat_count(&p->ticks, 1);
		mb_lat_max(&p->max_late, late);
		mb_lat_max(&p->max_stall, stall);
		atomic_store_explicit(&p->last_cpu, cpu, memory_order_relaxed);

		// This second
		mb_lat_record *c = &p->cur;
		p->sh[0][mb_lat_bucket(late)]++;
		if (p->mem != NULL) {
			p->sh[1][mb_lat_bucket(mem_ns)]++;
		}
		if (p->cpu_iterations > 0) {
			p->sh[2][mb_lat_bucket(cpu_ns)]++;
		}
		c->ticks++;
		c->late_sum += late;
		if (late > c->late_ns) {
			c->late_ns = late;
		}
		if (mem_ns > c->mem_ns) {
			c->mem_ns = mem_ns;
		}
		if (cpu_ns > c->cpu_ns) {
			c->cpu_ns = cpu_ns;
		}
		if (stall > c->stall_ns) {
			c->stall_ns = stall;
			c->worst_wall_ns = wall;
		}
		if (cpu != last_cpu) {
			c->migrations++;
			last_cpu = cpu;
		}
		c->cpu = cpu;

		if (over) {
			mb_lat_count(&p->over, 1);
			c->over++;

			// A tick event, while this second has room for one
			if (c->events < p->events_per_second) {
				mb_lat_record t;
				memset(&t, 0, sizeof(t));
				t.kind = MB_LAT_KIND_TICK;
				t.cpu = cpu;
				t.wall_ns = wall;
				t.mono_ns = wake - start;
				t.late_ns = late;
				t.mem_ns = mem_ns;
				t.cpu_ns = cpu_ns;
				t.tcpu_ns = tcpu_ns;
				t.stall_ns = stall;
				c->events++;
				mb_lat_count(&p->events, 1);
				mb_lat_push(p, &t, 0);
			} else {
				c->dropped++;
				mb_lat_count(&p->dropped, 1);
			}

			// The stall episode this tick belongs to: from the deadline it
			// missed (or the start of its work) to the end of its work
			int64_t from = late > p->threshold_ns ? next : wake;
			int64_t from_wall = wall - (wake - from);
			if (!p->ep_open) {
				memset(&p->ep, 0, sizeof(p->ep));
				p->ep.kind = MB_LAT_KIND_EPISODE;
				p->ep.wall_ns = from_wall;
				p->ep.mono_ns = from - start;
				p->ep_open = 1;
			}
			mb_lat_record *e = &p->ep;
			e->over++;
			e->end_mono_ns = done - start;
			if (late > e->late_ns) {
				e->late_ns = late;
			}
			if (mem_ns > e->mem_ns) {
				e->mem_ns = mem_ns;
				e->tcpu_ns = tcpu_ns;
			}
			if (cpu_ns > e->cpu_ns) {
				e->cpu_ns = cpu_ns;
			}
			if (stall > e->stall_ns) {
				e->stall_ns = stall;
				e->worst_wall_ns = wall;
				e->cpu = cpu;
			}
			p->ep_last_over = done;
		}

		if (p->ep_open) {
			p->ep.ticks++;
			if ((!over && wake - p->ep_last_over > p->gap_ns) || done - start - p->ep.mono_ns > MB_LAT_EPISODE_MAX_NS) {
				mb_lat_episode_close(p);
			}
		}

		// The next deadline; deadlines already passed are missed ticks
		next += p->period_ns;
		int64_t now = mb_lat_mono_ns();
		if (now >= next) {
			int64_t k = (now - next) / p->period_ns + 1;
			next += k * p->period_ns;
			mb_lat_count(&p->missed, (uint64_t)k);
			c->missed += k;
			if (p->ep_open) {
				p->ep.missed += k;
			}
		}
	}

	mb_lat_episode_close(p);
	mb_lat_second_end(p);
	atomic_store(&p->running, 0);

	// Wake a waiting consumer for the last records
	pthread_mutex_lock(&p->mu);
	pthread_cond_broadcast(&p->cond);
	pthread_mutex_unlock(&p->mu);

	return NULL;
}

/* Ruby object */

static VALUE cProbe;
static VALUE sym_second, sym_episode, sym_tick;

static void mb_lat_join(mb_lat_probe *p)
{
	if (!p->started) {
		return;
	}
	p->started = 0;
	if (p->pid != getpid()) {
		// A forked child: the thread lives only in the parent
		return;
	}
	atomic_store(&p->stop, 1);
	pthread_join(p->thread, NULL);
}

static void mb_lat_release(mb_lat_probe *p)
{
	if (p->mem != NULL) {
		if (p->mlocked) {
			munlock(p->mem, p->mem_bytes);
		}
		free(p->mem);
		p->mem = NULL;
	}
}

static void probe_free(void *ptr)
{
	mb_lat_probe *p = ptr;
	mb_lat_join(p);
	mb_lat_release(p);
	free(p->ring);
	pthread_mutex_destroy(&p->mu);
	pthread_cond_destroy(&p->cond);
	free(p);
}

static size_t probe_memsize(const void *ptr)
{
	const mb_lat_probe *p = ptr;
	return sizeof(*p) + p->ring_cap * sizeof(mb_lat_record) + (p->mem ? p->mem_bytes : 0);
}

static const rb_data_type_t probe_type = {
	.wrap_struct_name = "MB::Sound::FastLatency::Probe",
	.function = {
		.dmark = NULL,
		.dfree = probe_free,
		.dsize = probe_memsize,
	},
	.flags = 0,
};

static mb_lat_probe *get_probe(VALUE self)
{
	mb_lat_probe *p;
	TypedData_Get_Struct(self, mb_lat_probe, &probe_type, p);
	return p;
}

static VALUE probe_alloc(VALUE klass)
{
	mb_lat_probe *p = calloc(1, sizeof(mb_lat_probe));
	if (p == NULL) {
		rb_raise(rb_eNoMemError, "Couldn't allocate a latency probe");
	}
	pthread_mutex_init(&p->mu, NULL);
	pthread_cond_init(&p->cond, NULL);
	p->pin_cpu = -1;
	return TypedData_Wrap_Struct(klass, &probe_type, p);
}

static VALUE opt(VALUE h, const char *name)
{
	return rb_hash_aref(h, ID2SYM(rb_intern(name)));
}

static int64_t opt_i64(VALUE h, const char *name, int64_t def, int64_t min, int64_t max)
{
	VALUE v = opt(h, name);
	if (NIL_P(v)) {
		return def;
	}
	int64_t x = NUM2LL(v);
	if (x < min || x > max) {
		rb_raise(rb_eArgError, "%s must be %lld..%lld (got %lld)", name, (long long)min, (long long)max, (long long)x);
	}
	return x;
}

/*
 * Probe.new(options Hash): nothing runs until #start.  Options (Integers
 * in nanoseconds or bytes; the Ruby side, LatencyProbe, converts units):
 * :period_ns (1 ms), :threshold_ns (2 ms), :gap_ns (episodes merge over
 * gaps up to this, 100 ms), :work_ratio (4.0) and :work_min_ns (50 us)
 * (work over ratio x its baseline and longer by min counts as a stall too),
 * :memory_bytes (0: no memory probe), :memory_touch (bytes walked per
 * tick, 256 KiB), :cpu_iterations (0: no CPU probe), :events_per_second
 * (100), :ring (records, rounded up to a power of two, 4096), :boost
 * (true), :rt_priority (10), :nice (-10), :pin_cpu (nil), :mlock (false).
 */
static VALUE probe_initialize(VALUE self, VALUE h)
{
	mb_lat_probe *p = get_probe(self);
	Check_Type(h, T_HASH);
	if (p->ring != NULL) {
		rb_raise(rb_eRuntimeError, "Probe already initialized");
	}

	p->period_ns = opt_i64(h, "period_ns", 1000000, 10000, 10000000000LL);
	p->threshold_ns = opt_i64(h, "threshold_ns", 2000000, 0, INT64_MAX);
	p->gap_ns = opt_i64(h, "gap_ns", 100000000, 0, INT64_MAX);
	p->work_min_ns = opt_i64(h, "work_min_ns", 50000, 0, INT64_MAX);
	VALUE ratio = opt(h, "work_ratio");
	p->work_ratio = NIL_P(ratio) ? 4.0 : NUM2DBL(ratio);
	p->mem_bytes = (size_t)opt_i64(h, "memory_bytes", 0, 0, (int64_t)1 << 40);
	p->mem_touch = (size_t)opt_i64(h, "memory_touch", 256 * 1024, 64, (int64_t)1 << 32);
	p->cpu_iterations = opt_i64(h, "cpu_iterations", 0, 0, INT64_MAX);
	p->events_per_second = opt_i64(h, "events_per_second", 100, 0, INT64_MAX);
	int64_t ring = opt_i64(h, "ring", 4096, 2, 1 << 24);
	p->boost = RTEST(rb_hash_lookup2(h, ID2SYM(rb_intern("boost")), Qtrue));
	p->rt_priority = (int)opt_i64(h, "rt_priority", 10, 0, 99);
	p->nice = (int)opt_i64(h, "nice", -10, -20, 19);
	p->pin_cpu = (int)opt_i64(h, "pin_cpu", -1, -1, 4095);
	p->want_mlock = RTEST(opt(h, "mlock"));

	uint64_t cap = 2;
	while (cap < (uint64_t)ring) {
		cap <<= 1;
	}
	p->ring_cap = cap;
	p->ring = calloc(cap, sizeof(mb_lat_record));
	if (p->ring == NULL) {
		rb_raise(rb_eNoMemError, "Couldn't allocate the latency probe's ring");
	}
	p->cpu_state = 0x9e3779b97f4a7c15ULL;

	return self;
}

/*
 * #start -> self: allocates and touches the memory probe's buffer (here, on
 * the calling thread), then starts the probe thread and waits until it has
 * set itself up.  Raises if already started.
 */
static VALUE probe_start(VALUE self)
{
	mb_lat_probe *p = get_probe(self);
	if (p->ring == NULL) {
		rb_raise(rb_eRuntimeError, "Probe not initialized");
	}
	if (p->started) {
		rb_raise(rb_eRuntimeError, "Probe already started");
	}

	if (p->mem_bytes > 0 && p->mem == NULL) {
		p->mem_bytes = (p->mem_bytes + 63) & ~(size_t)63;
		p->mem = malloc(p->mem_bytes);
		if (p->mem == NULL) {
			rb_raise(rb_eNoMemError, "Couldn't allocate %zu bytes for the memory probe", p->mem_bytes);
		}
		memset(p->mem, 1, p->mem_bytes);
		if (p->want_mlock) {
			p->mlocked = mlock(p->mem, p->mem_bytes) == 0 && mlock(p->ring, p->ring_cap * sizeof(mb_lat_record)) == 0;
		}
	}

	atomic_store(&p->stop, 0);
	atomic_store(&p->running, 0);
	p->pid = getpid();
	int r = pthread_create(&p->thread, NULL, mb_lat_probe_main, p);
	if (r != 0) {
		rb_raise(rb_eRuntimeError, "Couldn't start the latency probe thread: %s", strerror(r));
	}
	p->started = 1;

	// Wait (briefly, with the GVL: setup takes microseconds) for it to run
	for (int i = 0; i < 100000 && !atomic_load(&p->running); i++) {
		usleep(10);
	}
	return self;
}

static void *probe_join_nogvl(void *arg)
{
	mb_lat_join(arg);
	return NULL;
}

// #stop -> self: stops the probe thread and waits for it (without the GVL).
// Records it pushed stay in the ring for #drain.
static VALUE probe_stop(VALUE self)
{
	mb_lat_probe *p = get_probe(self);
	if (p->started) {
		rb_thread_call_without_gvl(probe_join_nogvl, p, NULL, NULL);
	}
	return self;
}

static VALUE probe_running_p(VALUE self)
{
	mb_lat_probe *p = get_probe(self);
	return (p->started && p->pid == getpid() && atomic_load(&p->running)) ? Qtrue : Qfalse;
}

struct mb_lat_wait {
	mb_lat_probe *p;
	int64_t timeout_ns;
	int ready;
};

static int mb_lat_has_data(mb_lat_probe *p)
{
	return atomic_load_explicit(&p->head, memory_order_acquire) != atomic_load_explicit(&p->tail, memory_order_relaxed);
}

static void *probe_wait_nogvl(void *arg)
{
	struct mb_lat_wait *w = arg;
	mb_lat_probe *p = w->p;

	int64_t deadline = mb_lat_wall_ns() + w->timeout_ns;
	struct timespec ts = { .tv_sec = deadline / 1000000000LL, .tv_nsec = deadline % 1000000000LL };

	pthread_mutex_lock(&p->mu);
	while (!mb_lat_has_data(p) && !p->interrupt && atomic_load(&p->running) && !atomic_load(&p->stop)) {
		if (pthread_cond_timedwait(&p->cond, &p->mu, &ts) == ETIMEDOUT) {
			break;
		}
	}
	p->interrupt = 0;
	pthread_mutex_unlock(&p->mu);

	w->ready = mb_lat_has_data(p);
	return NULL;
}

static void probe_wait_ubf(void *arg)
{
	mb_lat_probe *p = arg;
	pthread_mutex_lock(&p->mu);
	p->interrupt = 1;
	pthread_cond_broadcast(&p->cond);
	pthread_mutex_unlock(&p->mu);
}

/*
 * #wait(timeout_seconds) -> true if records are waiting: blocks without the
 * GVL until the probe pushes a second or an episode, the ring fills past
 * half, the probe stops, the timeout passes, or the thread is interrupted
 * (Thread#raise/#kill).
 */
static VALUE probe_wait(VALUE self, VALUE timeout)
{
	mb_lat_probe *p = get_probe(self);
	double t = NUM2DBL(timeout);
	if (t < 0) {
		t = 0;
	}
	struct mb_lat_wait w = { .p = p, .timeout_ns = (int64_t)(t * 1e9), .ready = 0 };
	rb_thread_call_without_gvl(probe_wait_nogvl, &w, probe_wait_ubf, p);
	return w.ready ? Qtrue : Qfalse;
}

#define SET(h, k, v) rb_hash_aset((h), ID2SYM(rb_intern(k)), (v))

static VALUE record_hash(const mb_lat_record *r)
{
	VALUE h = rb_hash_new();
	switch (r->kind) {
	case MB_LAT_KIND_SECOND:
		SET(h, "kind", sym_second);
		SET(h, "second", LL2NUM(r->wall_ns / 1000000000LL));
		SET(h, "ticks", LL2NUM(r->ticks));
		SET(h, "missed", LL2NUM(r->missed));
		SET(h, "over", LL2NUM(r->over));
		SET(h, "events", LL2NUM(r->events));
		SET(h, "dropped", LL2NUM(r->dropped));
		SET(h, "late_max_ns", LL2NUM(r->late_ns));
		SET(h, "late_p50_ns", LL2NUM(r->late_p50));
		SET(h, "late_p99_ns", LL2NUM(r->late_p99));
		SET(h, "late_sum_ns", LL2NUM(r->late_sum));
		SET(h, "mem_max_ns", LL2NUM(r->mem_ns));
		SET(h, "mem_p50_ns", LL2NUM(r->mem_p50));
		SET(h, "mem_p99_ns", LL2NUM(r->mem_p99));
		SET(h, "cpu_max_ns", LL2NUM(r->cpu_ns));
		SET(h, "cpu_p50_ns", LL2NUM(r->cpu_p50));
		SET(h, "cpu_p99_ns", LL2NUM(r->cpu_p99));
		SET(h, "stall_max_ns", LL2NUM(r->stall_ns));
		SET(h, "worst_wall_ns", LL2NUM(r->worst_wall_ns));
		SET(h, "thread_cpu_ns", LL2NUM(r->tcpu_ns));
		SET(h, "nvcsw", LL2NUM(r->nvcsw));
		SET(h, "nivcsw", LL2NUM(r->nivcsw));
		SET(h, "migrations", LL2NUM(r->migrations));
		SET(h, "cpu", INT2NUM(r->cpu));
		break;

	case MB_LAT_KIND_EPISODE:
		SET(h, "kind", sym_episode);
		SET(h, "wall_ns", LL2NUM(r->wall_ns));
		SET(h, "mono_ns", LL2NUM(r->mono_ns));
		SET(h, "duration_ns", LL2NUM(r->end_mono_ns - r->mono_ns));
		SET(h, "worst_wall_ns", LL2NUM(r->worst_wall_ns));
		SET(h, "ticks", LL2NUM(r->ticks));
		SET(h, "over", LL2NUM(r->over));
		SET(h, "missed", LL2NUM(r->missed));
		SET(h, "late_ns", LL2NUM(r->late_ns));
		SET(h, "mem_ns", LL2NUM(r->mem_ns));
		SET(h, "mem_thread_cpu_ns", LL2NUM(r->tcpu_ns));
		SET(h, "cpu_ns", LL2NUM(r->cpu_ns));
		SET(h, "stall_ns", LL2NUM(r->stall_ns));
		SET(h, "cpu", INT2NUM(r->cpu));
		break;

	default:
		SET(h, "kind", sym_tick);
		SET(h, "wall_ns", LL2NUM(r->wall_ns));
		SET(h, "mono_ns", LL2NUM(r->mono_ns));
		SET(h, "late_ns", LL2NUM(r->late_ns));
		SET(h, "mem_ns", LL2NUM(r->mem_ns));
		SET(h, "mem_thread_cpu_ns", LL2NUM(r->tcpu_ns));
		SET(h, "cpu_ns", LL2NUM(r->cpu_ns));
		SET(h, "stall_ns", LL2NUM(r->stall_ns));
		SET(h, "cpu", INT2NUM(r->cpu));
		break;
	}
	return h;
}

/*
 * #drain(max = nil) -> Array of Hashes: the records waiting in the ring,
 * oldest first (kinds :second, :episode, :tick; times in nanoseconds,
 * wall times since the epoch, mono times since the probe started).
 */
static VALUE probe_drain(int argc, VALUE *argv, VALUE self)
{
	mb_lat_probe *p = get_probe(self);
	VALUE max;
	rb_scan_args(argc, argv, "01", &max);
	uint64_t limit = NIL_P(max) ? UINT64_MAX : (uint64_t)NUM2ULL(max);

	VALUE out = rb_ary_new();
	if (p->ring == NULL) {
		return out;
	}

	uint64_t tail = atomic_load_explicit(&p->tail, memory_order_relaxed);
	uint64_t head = atomic_load_explicit(&p->head, memory_order_acquire);
	for (uint64_t n = 0; tail != head && n < limit; n++) {
		mb_lat_record r = p->ring[tail & (p->ring_cap - 1)];
		tail++;
		atomic_store_explicit(&p->tail, tail, memory_order_release);
		rb_ary_push(out, record_hash(&r));
	}
	return out;
}

// #stats -> Hash: lifetime counters and what the probe thread obtained.
static VALUE probe_stats(VALUE self)
{
	mb_lat_probe *p = get_probe(self);
	VALUE h = rb_hash_new();
	SET(h, "ticks", ULL2NUM(atomic_load(&p->ticks)));
	SET(h, "missed", ULL2NUM(atomic_load(&p->missed)));
	SET(h, "over", ULL2NUM(atomic_load(&p->over)));
	SET(h, "events", ULL2NUM(atomic_load(&p->events)));
	SET(h, "dropped", ULL2NUM(atomic_load(&p->dropped)));
	SET(h, "episodes", ULL2NUM(atomic_load(&p->episodes)));
	SET(h, "overflow", ULL2NUM(atomic_load(&p->overflow)));
	SET(h, "queued", ULL2NUM(atomic_load(&p->head) - atomic_load(&p->tail)));
	SET(h, "ring", ULL2NUM(p->ring_cap));
	SET(h, "max_late_ns", LL2NUM(atomic_load(&p->max_late)));
	SET(h, "max_stall_ns", LL2NUM(atomic_load(&p->max_stall)));
	SET(h, "calibrated", atomic_load(&p->calibrated) ? Qtrue : Qfalse);
	SET(h, "memory_base_ns", atomic_load(&p->calibrated) && p->mem_bytes > 0 ? LL2NUM(atomic_load(&p->mem_base)) : Qnil);
	SET(h, "cpu_base_ns", atomic_load(&p->calibrated) && p->cpu_iterations > 0 ? LL2NUM(atomic_load(&p->cpu_base)) : Qnil);
	SET(h, "start_mono_ns", LL2NUM(atomic_load(&p->start_mono)));
	SET(h, "start_wall_ns", LL2NUM(atomic_load(&p->start_wall)));
	SET(h, "cpu", INT2NUM(atomic_load(&p->last_cpu)));
	SET(h, "priority", p->priority[0] ? rb_str_new_cstr(p->priority) : Qnil);
	SET(h, "error", p->error[0] ? rb_str_new_cstr(p->error) : Qnil);
	SET(h, "mlocked", p->mlocked ? Qtrue : Qfalse);
	SET(h, "period_ns", LL2NUM(p->period_ns));
	SET(h, "threshold_ns", LL2NUM(p->threshold_ns));
	SET(h, "memory_bytes", ULL2NUM(p->mem_bytes));
	SET(h, "memory_touch", ULL2NUM(p->mem_bytes > 0 ? p->mem_touch : 0));
	SET(h, "cpu_iterations", LL2NUM(p->cpu_iterations));
	SET(h, "running", probe_running_p(self));
	return h;
}

/*
 * #histogram(kind) -> Array of counts per bucket (FastLatency.bucket):
 * kind 0 or :late (wake lateness), 1 or :memory (memory work durations), 2
 * or :cpu (CPU work durations), 3 or :stall (per tick, the larger of the
 * lateness and the work's excess over its baseline).
 */
static VALUE probe_histogram(VALUE self, VALUE kind)
{
	mb_lat_probe *p = get_probe(self);
	int k;
	if (SYMBOL_P(kind)) {
		ID id = SYM2ID(kind);
		if (id == rb_intern("late")) k = 0;
		else if (id == rb_intern("memory")) k = 1;
		else if (id == rb_intern("cpu")) k = 2;
		else if (id == rb_intern("stall")) k = 3;
		else rb_raise(rb_eArgError, "Histogram kinds are :late, :memory, :cpu, :stall");
	} else {
		k = NUM2INT(kind);
		if (k < 0 || k >= MB_LAT_HISTS) {
			rb_raise(rb_eArgError, "Histogram kinds are 0..%d", MB_LAT_HISTS - 1);
		}
	}

	VALUE out = rb_ary_new_capa(MB_LAT_BUCKETS);
	for (int i = 0; i < MB_LAT_BUCKETS; i++) {
		rb_ary_push(out, ULL2NUM(atomic_load_explicit(&p->hist[k][i], memory_order_relaxed)));
	}
	return out;
}

/* Module functions */

// FastLatency.bucket(ns) -> the histogram bucket index of +ns+.
static VALUE fl_bucket(VALUE self, VALUE ns)
{
	return INT2NUM(mb_lat_bucket(NUM2LL(ns)));
}

// FastLatency.bucket_floor(i) -> the smallest value in bucket +i+.
static VALUE fl_bucket_floor(VALUE self, VALUE i)
{
	int b = NUM2INT(i);
	if (b < 0 || b >= MB_LAT_BUCKETS) {
		rb_raise(rb_eIndexError, "Buckets are 0..%d", MB_LAT_BUCKETS - 1);
	}
	return LL2NUM(mb_lat_bucket_floor(b));
}

// FastLatency.percentile(counts, q) -> the value the probe reports for
// quantile +q+ of a per-second histogram (+counts+ an Array of bucket
// counts, each under 2^32).
static VALUE fl_percentile(VALUE self, VALUE counts, VALUE q)
{
	Check_Type(counts, T_ARRAY);
	if (RARRAY_LEN(counts) != MB_LAT_BUCKETS) {
		rb_raise(rb_eArgError, "Pass %d bucket counts", MB_LAT_BUCKETS);
	}
	uint32_t c[MB_LAT_BUCKETS];
	for (int i = 0; i < MB_LAT_BUCKETS; i++) {
		c[i] = (uint32_t)NUM2UINT(rb_ary_entry(counts, i));
	}
	return LL2NUM(mb_lat_percentile_u32(c, NUM2DBL(q)));
}

// FastLatency.spin(seconds) -> nil: busy-waits holding the GVL (no
// interrupt checks), for specs and demonstrations of a Ruby-side stall.
static VALUE fl_spin(VALUE self, VALUE seconds)
{
	int64_t end = mb_lat_mono_ns() + (int64_t)(NUM2DBL(seconds) * 1e9);
	uint64_t x = 1;
	while (mb_lat_mono_ns() < end) {
		x = mb_lat_spin_cpu(x, 100);
	}
	mb_lat_sink += (int64_t)(x & 1);
	return Qnil;
}

// FastLatency.mono_ns -> the probe's monotonic clock, in nanoseconds.
static VALUE fl_mono_ns(VALUE self)
{
	return LL2NUM(mb_lat_mono_ns());
}

/*
 * FastLatency.system_sample -> Hash: what the consumer samples once a second
 * besides the probe's own records, read cheaply on the calling thread (never
 * on the probe thread).  Everywhere :load1, :load5, :load15 (getloadavg).
 * On macOS also host CPU ticks (:cpu_user, :cpu_system, :cpu_nice,
 * :cpu_idle; HOST_CPU_LOAD_INFO) and memory (:mem_total, :mem_free,
 * :mem_inactive, :mem_wired, :mem_compressed, :mem_available = free +
 * inactive + speculative + purgeable, in bytes; host_statistics64 like
 * vm_stat).  Linux reads the rest from /proc in Ruby (LatencyProbe::System).
 */
static VALUE fl_system_sample(VALUE self)
{
	VALUE h = rb_hash_new();
	double load[3];
	if (getloadavg(load, 3) == 3) {
		SET(h, "load1", DBL2NUM(load[0]));
		SET(h, "load5", DBL2NUM(load[1]));
		SET(h, "load15", DBL2NUM(load[2]));
	}

#ifdef __APPLE__
	host_t host = mach_host_self();

	host_cpu_load_info_data_t cpu;
	mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
	if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
		SET(h, "cpu_user", ULL2NUM(cpu.cpu_ticks[CPU_STATE_USER]));
		SET(h, "cpu_system", ULL2NUM(cpu.cpu_ticks[CPU_STATE_SYSTEM]));
		SET(h, "cpu_nice", ULL2NUM(cpu.cpu_ticks[CPU_STATE_NICE]));
		SET(h, "cpu_idle", ULL2NUM(cpu.cpu_ticks[CPU_STATE_IDLE]));
	}

	vm_statistics64_data_t vm;
	count = HOST_VM_INFO64_COUNT;
	vm_size_t page = 0;
	host_page_size(host, &page);
	if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
		uint64_t ps = page;
		SET(h, "mem_free", ULL2NUM(vm.free_count * ps));
		SET(h, "mem_inactive", ULL2NUM(vm.inactive_count * ps));
		SET(h, "mem_wired", ULL2NUM(vm.wire_count * ps));
		SET(h, "mem_compressed", ULL2NUM(vm.compressor_page_count * ps));
		SET(h, "mem_available", ULL2NUM(((uint64_t)vm.free_count + vm.inactive_count + vm.speculative_count + vm.purgeable_count) * ps));
		SET(h, "pageins", ULL2NUM(vm.pageins));
		SET(h, "swapouts", ULL2NUM(vm.swapouts));
	}
	mach_port_deallocate(mach_task_self(), host);

	uint64_t total = 0;
	size_t len = sizeof(total);
	if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) == 0) {
		SET(h, "mem_total", ULL2NUM(total));
	}
#endif

	return h;
}

void Init_fast_latency(void)
{
#ifdef __APPLE__
	mach_timebase_info(&mb_lat_timebase);
#endif

	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fl = rb_define_module_under(sound, "FastLatency");

	sym_second = ID2SYM(rb_intern("second"));
	sym_episode = ID2SYM(rb_intern("episode"));
	sym_tick = ID2SYM(rb_intern("tick"));

	rb_define_const(fl, "BUCKETS", INT2NUM(MB_LAT_BUCKETS));
	rb_define_const(fl, "SUB_BITS", INT2NUM(MB_LAT_SUB_BITS));
	rb_define_const(fl, "MAX_EXP", INT2NUM(MB_LAT_MAX_EXP));
	rb_define_const(fl, "CALIBRATION_TICKS", INT2NUM(MB_LAT_CALIBRATION));
#ifdef __APPLE__
	rb_define_const(fl, "WAKE_CLOCK", rb_str_new_cstr("mach_wait_until"));
#else
	rb_define_const(fl, "WAKE_CLOCK", rb_str_new_cstr("clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)"));
#endif

	rb_define_module_function(fl, "bucket", fl_bucket, 1);
	rb_define_module_function(fl, "bucket_floor", fl_bucket_floor, 1);
	rb_define_module_function(fl, "percentile", fl_percentile, 2);
	rb_define_module_function(fl, "spin", fl_spin, 1);
	rb_define_module_function(fl, "mono_ns", fl_mono_ns, 0);
	rb_define_module_function(fl, "system_sample", fl_system_sample, 0);

	cProbe = rb_define_class_under(fl, "Probe", rb_cObject);
	rb_define_alloc_func(cProbe, probe_alloc);
	rb_define_method(cProbe, "initialize", probe_initialize, 1);
	rb_define_method(cProbe, "start", probe_start, 0);
	rb_define_method(cProbe, "stop", probe_stop, 0);
	rb_define_method(cProbe, "running?", probe_running_p, 0);
	rb_define_method(cProbe, "wait", probe_wait, 1);
	rb_define_method(cProbe, "drain", probe_drain, -1);
	rb_define_method(cProbe, "stats", probe_stats, 0);
	rb_define_method(cProbe, "histogram", probe_histogram, 1);
}
