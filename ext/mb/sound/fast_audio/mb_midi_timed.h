/*
 * Timed MIDI output: short messages (1 to 3 bytes: channel messages and
 * realtime bytes such as clock ticks) stamped with when they must leave,
 * handed from one producer thread (Ruby's render thread) to the JACK
 * process thread without locks or allocation.
 *
 * A record names either a JACK frame time (mb_midi_timed_put) or a frame
 * of an audio output's ring plus an offset (mb_midi_timed_put_ring): the
 * message leaves +offset+ frames after that ring frame's audio.  Ring
 * records wait (in the pending array) until the consumer's conversion
 * callback can say exactly which JACK frame the ring frame leaves on (once
 * its audio is queued: before that, a cycle the ring runs short in, at the
 * start or in an underrun, would move it), then join the others.
 *
 * The producer appends records to a single-producer, single-consumer ring.
 * Each process cycle the consumer moves new records into a staging array
 * kept sorted by frame (stable: equal frames keep their order), converts
 * the pending ring records it can, then writes the records due in the
 * cycle at their frame offsets (late ones at offset 0) and keeps the rest
 * for later cycles.  So several writers' events (tracks on one port, each
 * writing a buffer's notes in order) come out sorted, as JACK requires, and
 * events never depend on when the producer happened to run, only on their
 * frames.
 *
 * Frames are JACK frame times (32 bits, wrapping): compared as signed
 * differences from the cycle's start, so events within 2**31 frames (12
 * hours at 48 kHz) of now sort correctly.  Ring frames are the low 32 bits
 * of the ring position, compared the same way.
 */
#ifndef MB_MIDI_TIMED_H
#define MB_MIDI_TIMED_H

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define MB_MIDI_TIMED_RING 8192 // records in the ring (a power of two)
#define MB_MIDI_TIMED_STAGE 4096 // records waiting for their cycle
#define MB_MIDI_TIMED_PEND 2048 // ring records waiting for their audio

struct mb_midi_timed_record {
	uint32_t frame; // a JACK frame time, or a ring frame if ring is set
	int32_t offset; // ring records: frames after the ring frame's audio
	uint32_t source; // ring records: which ring (the conversion's serial)
	uint8_t ring;
	uint8_t size;
	uint8_t bytes[3];
};

// The consumer's conversion of a ring record: sets *frame to the JACK
// frame time its ring frame's audio leaves on and returns 1, returns 0 to
// keep it waiting, or returns -1 when its ring is gone (*frame set to the
// cycle's start: it leaves now, counted late).
typedef int (*mb_midi_timed_convert_fn)(void *ctx, const struct mb_midi_timed_record *r, uint32_t now,
		uint32_t nframes, uint32_t *frame);

struct mb_midi_timed {
	struct mb_midi_timed_record ring[MB_MIDI_TIMED_RING];
	_Atomic size_t write_pos; // producer
	_Atomic size_t read_pos; // consumer

	// The consumer's (JACK thread's) sorted staging array
	struct mb_midi_timed_record stage[MB_MIDI_TIMED_STAGE];
	size_t stage_count;

	// The consumer's ring records waiting for their audio (any order)
	struct mb_midi_timed_record pend[MB_MIDI_TIMED_PEND];
	size_t pend_count;
	_Atomic size_t waiting; // pend_count, for the producer's stats

	_Atomic size_t sent; // records written to the port
	_Atomic size_t late; // ... of which after their frame (sent at offset 0)
	_Atomic size_t dropped; // records that found the ring or the stage full
	_Atomic int32_t max_late; // the latest any record was sent, in frames

	// Producer's request to drop everything queued before ring position
	// discard_to (panic); the consumer acts on it once (discard_seen)
	_Atomic size_t discard_to;
	size_t discard_seen;
};

// The byte count of a short message with status byte +status+, or 0 for
// statuses the timed path doesn't carry (SysEx and its end, undefined ones).
static inline int mb_midi_timed_size(uint8_t status)
{
	if (status < 0x80) {
		return 0;
	}
	if (status < 0xF0) {
		uint8_t kind = status & 0xF0;
		return kind == 0xC0 || kind == 0xD0 ? 2 : 3;
	}
	switch (status) {
	case 0xF1: case 0xF3: return 2; // MTC quarter frame, song select
	case 0xF2: return 3; // song position
	case 0xF6: case 0xF8: case 0xFA: case 0xFB: case 0xFC: case 0xFE: case 0xFF: return 1;
	default: return 0;
	}
}

// Producer: queues one record.  Returns 0, or -1 if the ring is full (the
// record is dropped and counted).
static inline int mb_midi_timed_put(struct mb_midi_timed *t, uint32_t frame, const uint8_t *bytes, int size)
{
	size_t wp = atomic_load_explicit(&t->write_pos, memory_order_relaxed);
	size_t rp = atomic_load_explicit(&t->read_pos, memory_order_acquire);
	if (wp - rp >= MB_MIDI_TIMED_RING) {
		atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
		return -1;
	}
	struct mb_midi_timed_record *r = &t->ring[wp & (MB_MIDI_TIMED_RING - 1)];
	r->frame = frame;
	r->offset = 0;
	r->source = 0;
	r->ring = 0;
	r->size = (uint8_t)size;
	memcpy(r->bytes, bytes, size);
	atomic_store_explicit(&t->write_pos, wp + 1, memory_order_release);
	return 0;
}

// Producer: queues one record to leave +offset+ frames after ring frame
// +ring_frame+ (low 32 bits) of the ring +source+ names (see
// mb_midi_timed_convert_fn).  Returns 0, or -1 if the ring is full.
static inline int mb_midi_timed_put_ring(struct mb_midi_timed *t, uint32_t ring_frame, int32_t offset, uint32_t source,
		const uint8_t *bytes, int size)
{
	size_t wp = atomic_load_explicit(&t->write_pos, memory_order_relaxed);
	size_t rp = atomic_load_explicit(&t->read_pos, memory_order_acquire);
	if (wp - rp >= MB_MIDI_TIMED_RING) {
		atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
		return -1;
	}
	struct mb_midi_timed_record *r = &t->ring[wp & (MB_MIDI_TIMED_RING - 1)];
	r->frame = ring_frame;
	r->offset = offset;
	r->source = source;
	r->ring = 1;
	r->size = (uint8_t)size;
	memcpy(r->bytes, bytes, size);
	atomic_store_explicit(&t->write_pos, wp + 1, memory_order_release);
	return 0;
}

// Producer side: records waiting in the ring (approximate; see also
// mb_midi_timed_waiting).
static inline size_t mb_midi_timed_pending(struct mb_midi_timed *t)
{
	return atomic_load_explicit(&t->write_pos, memory_order_acquire) -
		atomic_load_explicit(&t->read_pos, memory_order_acquire);
}

// Producer side: ring records waiting for their audio (approximate).
static inline size_t mb_midi_timed_waiting(struct mb_midi_timed *t)
{
	return atomic_load_explicit(&t->waiting, memory_order_relaxed);
}

// Producer: drops every record queued so far, in the ring and the stage
// (the consumer does it at its next cycle; records queued after this call
// stay).
static inline void mb_midi_timed_discard(struct mb_midi_timed *t)
{
	atomic_store_explicit(&t->discard_to, atomic_load_explicit(&t->write_pos, memory_order_relaxed), memory_order_release);
}

// Consumer: puts +r+ into the sorted stage (after the last staged record
// with a frame at or before its own; usually the end, since writers append
// in time order), or drops and counts it if the stage is full.
static inline void mb_midi_timed_insert(struct mb_midi_timed *t, const struct mb_midi_timed_record *r, uint32_t now)
{
	if (t->stage_count >= MB_MIDI_TIMED_STAGE) {
		atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
		return;
	}
	int32_t key = (int32_t)(r->frame - now);
	size_t lo = 0, hi = t->stage_count;
	if (hi == 0 || (int32_t)(t->stage[hi - 1].frame - now) <= key) {
		lo = hi;
	} else {
		while (lo < hi) {
			size_t mid = lo + (hi - lo) / 2;
			if ((int32_t)(t->stage[mid].frame - now) <= key) {
				lo = mid + 1;
			} else {
				hi = mid;
			}
		}
		memmove(&t->stage[lo + 1], &t->stage[lo], (t->stage_count - lo) * sizeof(*r));
	}
	t->stage[lo] = *r;
	t->stage_count++;
}

// Consumer: moves new ring records into the sorted stage, or for ring
// records the pending array (+now+ is the cycle's first frame).
static inline void mb_midi_timed_stage(struct mb_midi_timed *t, uint32_t now)
{
	size_t rp = atomic_load_explicit(&t->read_pos, memory_order_relaxed);
	size_t wp = atomic_load_explicit(&t->write_pos, memory_order_acquire);

	size_t discard = atomic_load_explicit(&t->discard_to, memory_order_acquire);
	if (discard != t->discard_seen) {
		t->discard_seen = discard;
		t->stage_count = 0;
		t->pend_count = 0;
		if (discard - rp <= wp - rp) {
			rp = discard;
		}
	}

	while (rp != wp) {
		struct mb_midi_timed_record r = t->ring[rp & (MB_MIDI_TIMED_RING - 1)];
		rp++;
		if (!r.ring) {
			mb_midi_timed_insert(t, &r, now);
		} else if (t->pend_count < MB_MIDI_TIMED_PEND) {
			t->pend[t->pend_count++] = r;
		} else {
			atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
		}
	}

	atomic_store_explicit(&t->read_pos, rp, memory_order_release);
	atomic_store_explicit(&t->waiting, t->pend_count, memory_order_relaxed);
}

// Consumer: converts the pending ring records +convert+ can place (see
// mb_midi_timed_convert_fn) into stage records at their JACK frame plus
// their offset; the rest keep waiting, in order.
static inline void mb_midi_timed_convert(struct mb_midi_timed *t, uint32_t now, uint32_t nframes,
		mb_midi_timed_convert_fn convert, void *ctx)
{
	size_t kept = 0;
	for (size_t i = 0; i < t->pend_count; i++) {
		struct mb_midi_timed_record r = t->pend[i];
		uint32_t frame;
		int done = convert(ctx, &r, now, nframes, &frame);
		if (done == 0) {
			t->pend[kept++] = r;
			continue;
		}
		if (done < 0) {
			atomic_fetch_add_explicit(&t->late, 1, memory_order_relaxed);
			r.offset = 0;
		}
		r.frame = frame + (uint32_t)r.offset;
		r.ring = 0;
		mb_midi_timed_insert(t, &r, now);
	}
	t->pend_count = kept;
	atomic_store_explicit(&t->waiting, kept, memory_order_relaxed);
}

// Consumer: writes the staged records due before +now+ + +nframes+ into
// the port +buffer+ (after any events already written there at offset 0)
// through +write+ (mb_jack_midi_write), keeping the rest.  Stops early if
// the port buffer is full (the rest wait for the next cycle).
static inline void mb_midi_timed_emit(struct mb_midi_timed *t, void *buffer, uint32_t now, uint32_t nframes,
		int (*write)(void *, uint32_t, const uint8_t *, size_t))
{
	size_t n = 0;
	while (n < t->stage_count) {
		struct mb_midi_timed_record *r = &t->stage[n];
		int32_t key = (int32_t)(r->frame - now);
		if (key >= (int32_t)nframes) {
			break;
		}
		uint32_t offset = key < 0 ? 0 : (uint32_t)key;
		if (write(buffer, offset, r->bytes, r->size) != 0) {
			break;
		}
		if (key < 0) {
			atomic_fetch_add_explicit(&t->late, 1, memory_order_relaxed);
			if (-key > atomic_load_explicit(&t->max_late, memory_order_relaxed)) {
				atomic_store_explicit(&t->max_late, -key, memory_order_relaxed);
			}
		}
		n++;
	}
	if (n > 0) {
		memmove(&t->stage[0], &t->stage[n], (t->stage_count - n) * sizeof(t->stage[0]));
		t->stage_count -= n;
		atomic_fetch_add_explicit(&t->sent, n, memory_order_relaxed);
	}
}

#endif
