/*
 * Timed MIDI output: short messages (1 to 3 bytes: channel messages and
 * realtime bytes such as clock ticks) stamped with the JACK frame they must
 * leave on, handed from one producer thread (Ruby's render thread) to the
 * JACK process thread without locks or allocation.
 *
 * The producer appends records to a single-producer, single-consumer ring.
 * Each process cycle the consumer moves new records into a staging array
 * kept sorted by frame (stable: equal frames keep their order), then
 * writes the records due in the cycle at their frame offsets (late ones at
 * offset 0) and keeps the rest for later cycles.  So several writers'
 * events (tracks on one port, each writing a buffer's notes in order) come
 * out sorted, as JACK requires, and events never depend on when the
 * producer happened to run, only on their frames.
 *
 * Frames are JACK frame times (32 bits, wrapping): compared as signed
 * differences from the cycle's start, so events within 2**31 frames (12
 * hours at 48 kHz) of now sort correctly.
 */
#ifndef MB_MIDI_TIMED_H
#define MB_MIDI_TIMED_H

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define MB_MIDI_TIMED_RING 8192 // records in the ring (a power of two)
#define MB_MIDI_TIMED_STAGE 4096 // records waiting for their cycle

struct mb_midi_timed_record {
	uint32_t frame;
	uint8_t size;
	uint8_t bytes[3];
};

struct mb_midi_timed {
	struct mb_midi_timed_record ring[MB_MIDI_TIMED_RING];
	_Atomic size_t write_pos; // producer
	_Atomic size_t read_pos; // consumer

	// The consumer's (JACK thread's) sorted staging array
	struct mb_midi_timed_record stage[MB_MIDI_TIMED_STAGE];
	size_t stage_count;

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
	r->size = (uint8_t)size;
	memcpy(r->bytes, bytes, size);
	atomic_store_explicit(&t->write_pos, wp + 1, memory_order_release);
	return 0;
}

// Producer side: records waiting in the ring or the stage (approximate).
static inline size_t mb_midi_timed_pending(struct mb_midi_timed *t)
{
	return atomic_load_explicit(&t->write_pos, memory_order_acquire) -
		atomic_load_explicit(&t->read_pos, memory_order_acquire);
}

// Producer: drops every record queued so far, in the ring and the stage
// (the consumer does it at its next cycle; records queued after this call
// stay).
static inline void mb_midi_timed_discard(struct mb_midi_timed *t)
{
	atomic_store_explicit(&t->discard_to, atomic_load_explicit(&t->write_pos, memory_order_relaxed), memory_order_release);
}

// Consumer: moves new ring records into the sorted stage (+now+ is the
// cycle's first frame).
static inline void mb_midi_timed_stage(struct mb_midi_timed *t, uint32_t now)
{
	size_t rp = atomic_load_explicit(&t->read_pos, memory_order_relaxed);
	size_t wp = atomic_load_explicit(&t->write_pos, memory_order_acquire);

	size_t discard = atomic_load_explicit(&t->discard_to, memory_order_acquire);
	if (discard != t->discard_seen) {
		t->discard_seen = discard;
		t->stage_count = 0;
		if (discard - rp <= wp - rp) {
			rp = discard;
		}
	}

	while (rp != wp) {
		struct mb_midi_timed_record r = t->ring[rp & (MB_MIDI_TIMED_RING - 1)];
		rp++;
		if (t->stage_count >= MB_MIDI_TIMED_STAGE) {
			atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
			continue;
		}

		// After the last staged record with a frame at or before this one
		// (usually the end: writers append in time order)
		int32_t key = (int32_t)(r.frame - now);
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
			memmove(&t->stage[lo + 1], &t->stage[lo], (t->stage_count - lo) * sizeof(r));
		}
		t->stage[lo] = r;
		t->stage_count++;
	}

	atomic_store_explicit(&t->read_pos, rp, memory_order_release);
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
