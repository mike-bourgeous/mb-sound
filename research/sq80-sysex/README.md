# Ensoniq SQ-80 / ESQ-1 program SysEx: format research

Branch `sq80-lib-1` (2026-10-17).  The question, in the maintainer's words: "I'd like a way to load an sq-80 patch in a live session in sound.rb, and have it show up in `help /sq80/`"; asked which meaning: "Both, library first" (our voice as a library patch now; real Ensoniq SQ-80 SysEx program import designed on top of it).  This note is the format research; the import design (parameter mapping, API, tests, decisions) is in `design/notes/sq80.md`, and the parser/writer built from it is `lib/mb/sound/sq80/sysex.rb`.

## Method

- A research agent read the SQ-80 Musician's Manual's MIDI implementation specification (pp. 189-196; scan on buchty.net), the ESQ-M manual, and the ESQ-1 OS 3 update, and compared them with three independent open-source code bases that read and write programs: SQ8L-revival (`SysEx.cpp`, a port of Siegfried Kullmann's SQ-80 emulator), stuartkeith/esq1 (`esq1.py`), and electronoora/esqbank (`esq_pcb.h`).  The three agree byte for byte.  Edisyn has no ESQ-1/SQ-80 editor.
- Local check (2026-10-17): four 40-program banks the maintainer dumped from his SQ-80 (kept outside the repository, in his gitignored `tmp/`; partly copyrighted factory and third-party sounds, partly possibly his own) were decoded with `SQ80::SysEx` and written back.  Only byte layout, counts, and checks are recorded here, nothing of the programs themselves.  Specs use synthetic dumps only (`spec/lib/mb/sound/sq80_sysex_spec.rb`); `MB_SOUND_SQ80_SYX_DIR=dir` adds a byte-for-byte round trip of each local bank.

## Format

Verified against the manual and all three code bases unless marked.

Messages: `F0 0F 02 0n <type> ... F7` (Ensoniq 0x0F; 0x02 is the ESQ family code shared by the ESQ-1, ESQ-M and SQ-80, so the header can't tell them apart; `n` the base MIDI channel, ignored by an importer).  Types: `01` one program (204 data bytes; 210 bytes in all), `02` all 40 internal programs (8160 data bytes; 8166 in all; the manual's "9160" is a typo), `09` current program dump request, `0A` all programs dump request, `0E` virtual keypad events, `10` compare-button status; `03`-`08`, `0C`, `0D`, `20`-`22` are sequence messages.  Only the universal Device ID reply (member 01 ESQ-1, 02 ESQ-M, 03 SQ-80) names the model.

Data: each byte of the 102-byte program as two nybbles, low first; programs back to back.

Program (offsets in bytes; s8x2 = signed -63..63 stored doubled as int8; s7 = 7-bit two's complement):

| Offset | Field |
|---|---|
| 0-5 | name, 6 characters 0x20-0x5F |
| 6 + 10e (e = 0..3) | ENV e+1: L1-L3 (s8x2), T1-T3 (bits 0-5), T4 (bits 0-5; bit 7 the SQ-80 second release "R"), LV (bits 2-7; bits 0-1 below), T1V, TK (bits 0-5) |
| 46 + 4l (l = 0..2) | LFO l+1: FREQ (bits 0-5) + WAVE (bits 6-7: tri, saw, square, noise); L1 (0-5) + mod source bits 3-2; L2 (0-5) + mod source bits 1-0; DELAY (0-5), HUMAN (6), RESET (7) |
| 58 + 10o (o = 0..2) | OSC o+1: pitch (OCT+3)*12 + SEMI; FINE (bits 3-7); pitch mod sources (lo, hi nybbles); MOD1, MOD2 amounts (s8x2); WAVE 0..74; DCA level (bits 1-6) + output on (7); DCA mod sources; DCA MOD1, MOD2 (s8x2) |
| 88 | DCA4 level (bits 1-6), AM (7) |
| 89 | FC 0..127, SYNC (7) |
| 90 | Q 0..31 |
| 91-93 | filter mod sources; MOD1 (s7) + VOICE RESTART (7); MOD2 (s7) + MONO (7) |
| 94 | filter KEYBD tracking (bits 1-6), ENV RESTART (7) |
| 95 | GLIDE (0-5), OSC RESTART (7) |
| 96-99 | split direction/key, layer, split, split-layer program bytes |
| 100 | PAN (hi nybble, 8 center), pan mod source (lo) |
| 101 | pan mod amount (s7), CYC (7) |

Mod sources (4 bits): 0-2 LFO1-3, 3-6 ENV1-4, 7 VEL, 8 VEL2 (VEL-X), 9 KYBD, 10 KYBD2, 11 WHEEL, 12 PEDAL, 13 XCTRL, 14 PRESS, 15 OFF.

Waves: 75 on the SQ-80 (0-31 the ESQ-1's), names in `SQ80::SysEx::WAVES`: classic shapes, noises, multisampled instruments (PIANO, EL PNO, VOICE1/2, BASS, CLAV, BRASS ...), additive tables described by their harmonics (SYNTH1-3, PRIME, 4 OCTS, OCTAVE, OCT+5, SQR 2, PULSE2, SAW 2), fixed-formant waves (FORMT1-5 at about 750 Hz, 1 k, 1.4 k, 1.75 k, 2.25 kHz; GLINT1-3), inharmonic loops (49-53), one-shot transients (54-64), drums and drum kits (65-74).

SQ-80 against ESQ-1: the same 102 bytes; only the content tells (waves 32-74, the second release bit, the LV flag).  The SQ-80 keyboard sends polyphonic pressure (PRESS reads it); the format has no flag for that.

UNVERIFIED:
- Which of the LV byte's bits 0-1 is the SQ-80's linear "L" / exponential "X" velocity curve flag.  The manual names the setting (p. 66) but not its bit; SQ8L ignores both bits.  In the local banks (below) bit 1 is set on about half the envelopes, including many with LV 0, and bit 0 on a few, so neither is ruled out by counting.  To settle it: a hardware dump of one program saved with each setting (LV 20L, 20X), or Arturia SQ80 V's exports.
- The split key's note mapping and whether program-number fields reach cartridge programs (split/layer is out of scope for a first importer).
- Every conversion of panel values to physical units beyond the envelope times (FC to Hz, Q, LFO FREQ to Hz, pitch mod depth per unit, DCA level curve, FINE step): not in the manual's tables; see the design's measurement plan.

## Local observations (2026-10-17)

Four files, 8166 bytes each, all `F0 0F 02 00 02` ... `F7` (40-program dumps on channel 1):

- Every data byte is a nybble (0x00-0x0F); 40 programs each; every name byte in 0x20-0x5F.
- Decoded ranges over all 160 programs are inside the documented ones: OSC octave -3..4, FINE 0..31, WAVE at most 74 (35-86% of oscillators per bank use SQ-80-only waves 32-74), envelope levels and every mod amount -63..63, LV 0..63, Q at most 31, PAN 5..9, 14 of 16 mod sources used.  Second release bits set on 20-35 of 160 envelopes per bank; flags all seen (AM 6, SYNC 25, MONO 3, voice/env/osc restart 46/98/95, CYC 28 of 160 programs).
- 154 of 160 programs are SQ-80-only by `Program#sq80_only?`.
- Decoding and writing back reproduces each file byte for byte once FINE's low three bits are kept as found (`fine_bits`; bit 2 is set on 29 of 480 oscillators, the junk bits the code bases mention).  So every bit the banks set is accounted for by the layout above.
- Not examined: the floppy images (SQ80 Toolkit format: `!SQ80BANK!` header and raw 102-byte programs, or native disk sectors) and the librarian's `.slb` files.

## Sources

- SQ-80 Musician's Manual (MIDI implementation pp. 189-200; envelopes pp. 59-66; waves pp. 33-39): http://www.buchty.net/ensoniq/files/manuals/SQ80.pdf
- ESQ-M Musician's Manual: http://www.buchty.net/ensoniq/files/manuals/ESQm.pdf
- ESQ-1 Software Version 3 Update (Device ID, compare message): http://www.buchty.net/ensoniq/files/manuals/os3u.pdf
- Rainer Buchty's Ensoniq page (collections, SQ80 Toolkit, OS 3.9 notes on LV/LX and the second release): http://www.buchty.net/ensoniq/ ; wave zone tables: http://www.buchty.net/ensoniq/files/waves.pdf
- SQ8L-revival: https://github.com/sq8l-revival/SQ8L
- stuartkeith/esq1: https://github.com/stuartkeith/esq1/blob/master/esq1.py
- electronoora/esqbank: https://github.com/electronoora/esqbank
- Edisyn (no ESQ-1/SQ-80 editor): https://github.com/eclab/edisyn/tree/master/edisyn/synth
