#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# 90s atmospheric jungle patches (a sliced-break sampler, sub, Reese,
# electric piano keys, string pad, flute, ride and shaker), playable from MIDI.
#
# Where they came from: the persona panel experiment of 2026-10-13
# (research branch research-persona-jungle, research/persona-panel/jungle/),
# in which a fictional persona, Nev Ashdown (a 90s atmospheric jungle
# producer recording as Skylark Junction), wrote the song "Memory Card"
# (bin/songs/memory_card.rb) with the public API.  The patches moved here so
# they can be played, reused, and saved as presets, named for the genre
# (patches-2, 2026-10-13).
#
# Patches (-p):
#   breaks  the sampler: a two-bar funk break "record" pressed from a
#           tuned-up tr808 bounced at 138.75 BPM (.jungle_record, a Sample),
#           at 12 bits, cut into sixteenths with 11 named slices on
#           11-semitone key zones (.jungle_sampler, a Sampler::Instrument;
#           sampler-1, 2026-10-13: was sample-mode Wavetables), one voice
#           (each slice cuts the last), a 13 kHz output filter, a touch of
#           sample-rate grit, a lowpass at --cutoff, tape softclip.  The
#           in-tempo key of each slice (3 semitones above its root, so the
#           record plays at 165 BPM) is .jungle_slice_keys: k (kick) Fs-1,
#           h (hat) F0, s (snare) E1, sk Ds2, g (ghost) D3, kk Cs4 (a
#           kick on the "and" of 3), s2 C5, k2 B5, s3 As6, full (the whole
#           record) A7, rev (a reversed snare) Gs8; each zone reaches 4
#           semitones below and 6 above its key (slower and lower, faster
#           and higher)
#   sub     a sine with a little 2nd harmonic, gliding between legato notes
#   reese   two saws 16 cents apart and an octave sine, a lowpass breathing
#           on a 2-bar LFO, warm softclip
#   keys    the tine piano (bin/synths/electric_pianos.rb) with a
#           stereo tremolo, in a hall (piano: :fm for the persona's own
#           phase-modulated keys)
#   pad     five saws per note, slow attack, Juno chorus, hall
#   flute   triangle and sine with bandpassed breath, delayed vibrato, a
#           dotted-eighth echo (--echo) and a hall
#   perc    the ride, shaker, and crash kit (tr808, GM note map)
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: jungle_breaks_voice(midi, cutoff:),
# jungle_sub_voice, jungle_reese_voice, jungle_keys_voice, jungle_pad_voice,
# jungle_flute_voice(midi, send:), jungle_perc.  Each is also a preset
# (presets/jungle_*.mbg.rb; the breaks are a bundle holding the slices):
# `preset :jungle_keys, midi: midi`.
#
# Usage:
#     bin/synths/jungle.rb                          # live MIDI, the keys
#     bin/synths/jungle.rb -p breaks -c 2500 song.mid breaks.flac
#     bin/synths/jungle.rb -p flute -e 0.6 song.mid flute.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/jungle.rb'`):
#     bpm 165
#     k = jungle_slice_keys
#     amen = seq(k[:k], T, k[:h], k[:g], k[:sk], T, T, T, k[:h], T, k[:kk], T, k[:s2], T, T, T).n16.loop
#     bg :breaks, jungle_breaks_voice(amen)
#     swap :breaks, amen.transpose(2)                            # chops pitched up a tone
#     brk = jungle_slices_of                                     # or chop the slices directly (slice and pitch apart):
#     bg :breaks, jungle_breaks_voice(brk.chop(:k, T, :h, :g, [:s, 2], T, brk[:s].rev, :kk).loop.transpose(3), map: brk.instrument)
#     bg :keys, jungle_keys_voice(seq([C3, E3, F3, A3].map(&:n2).reduce(:&), R.n2).loop)
#     bg :sub, jungle_sub_voice(seq(D2.n2.d, D2.n8, C2.n8, D2.n1).loop)

require 'bundler/setup'
require 'mb-sound'
require_relative 'electric_pianos'

module MB::Sound
  # The sampler's slices: { name => [first 16th of the record, length in
  # 16ths, reversed?] }, in key-zone order.
  def self.jungle_slices
    {
      k:    [0, 2],        # kick
      h:    [2, 2],        # hat
      s:    [4, 2],        # snare
      sk:   [4, 4],        # snare, ghost kick, ghost snare
      g:    [7, 1],        # ghost snare
      kk:   [10, 2],       # kick on the "and" of 3
      s2:   [12, 4],       # snare, open hat, ghost
      k2:   [16, 4],       # double kick with a ghost between
      s3:   [20, 4],       # snare with open hat
      full: [0, 32],       # the whole record
      rev:  [12, 4, true], # the snare and its tail, backwards
    }
  end

  # The in-tempo Note for each slice ({ Symbol => Note }): each slice's
  # key zone is +zone+ semitones wide from note 2 up, its sample root one
  # semitone above the zone's start, and the key that plays it
  # +transpose+ semitones above the root (3: the record's 138.75 BPM lands
  # on 165).
  def self.jungle_slice_keys(zone: 11, transpose: 3)
    jungle_slices.keys.each_with_index.to_h { |name, i| [name, Note.new(2 + i * zone + 1 + transpose)] }
  end

  # Presses the record: two bars of a funk break (+rows+ of 16ths; digits
  # are ghost-note velocities) on a tuned-up TR-808 kit bounced at +bpm+
  # (a private tempo, so the session's is untouched), through a small room
  # and a tape-ish softclip.  Returns a mono Sample (with its tempo, so
  # `rec.at(7.n16)` counts the record's sixteenths).
  def self.jungle_record(
    bpm: 165 / 2 ** (3 / 12.0), seed: 165,
    rows: {
      kick:     'X.....x...X.....|X.x.......X..x..',
      snare:    '....X..3.3..X..3|.3..X..3....X.3.',
      hat:      'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx',
      open_hat: '..............x.|......x.........',
    }
  )
    bounce(2.bars, bpm: bpm, name: 'jungle_record') {
      tr808(
        grid(16, **rows),
        kick: { tune: 58, decay: 0.32, tone: 0.65, level: 1.0 },
        snare: { tune: 205, decay: 0.16, tone: 0.7, snappy: 0.75, level: 1.0 },
        closed_hat: { decay: 0.045, tone: 0.75, level: 0.3 },
        open_hat: { decay: 0.25, tone: 0.7, level: 0.3 }, accent: 8.db, velocity_curve: :grid, seed: seed
      ).reverb(:room, mix: 0.18).softclip(0.5, 0.95)
    }
  end

  # The record at +bits+ (12, like the S950), cut into its 32 sixteenths,
  # with the names of .jungle_slices for its runs (a Sample::Slices; each
  # slice fades out over 2 ms).  `jungle_slices_of.chop(:k, T, :s, ...)`
  # writes chops for it directly, slice and pitch apart.
  def self.jungle_slices_of(record = nil, bpm: 165 / 2 ** (3 / 12.0), bits: 12)
    record ||= jungle_record(bpm: bpm)
    record = record.bits(bits) if bits
    names = jungle_slices.reject { |_, (_, _, reverse)| reverse }.transform_values { |start, steps| start..(start + steps - 1) }
    record.slices(at: (0...32).map { |i| i.n16 }).name(**names) # on the record's tempo grid
  end

  # The breaks sampler (a Sampler::Instrument): the slices of
  # .jungle_slices_of on key zones +zone+ semitones wide from note 2 up,
  # each slice's own pitch one semitone above its zone's start and
  # tracking the keys from there (see .jungle_slice_keys).  +record+ is a
  # Sample (.jungle_record by default).  (Chop clips from
  # .jungle_slices_of play on that Slices' own instrument: pass
  # `map: brk.instrument` to .jungle_breaks_voice.)
  def self.jungle_sampler(record = nil, bpm: 165 / 2 ** (3 / 12.0), bits: 12, zone: 11)
    brk = jungle_slices_of(record, bpm: bpm, bits: bits)
    MB::Sound::Sampler::Instrument.new { |inst|
      jungle_slices.each_with_index do |(name, (start, steps, reverse)), i|
        low = 2 + i * zone
        inst.region(reverse ? brk[start...(start + steps)].rev : brk[name], keys: low...(low + zone), root: low + 1)
      end
    }
  end

  # The breaks: one sampler voice playing +map+ (a Sampler::Instrument;
  # .jungle_sampler by default; each slice cuts the last, with a 1.3 ms
  # declick), a 13 kHz lowpass like the sampler's output filter, +grit+ of
  # sample-rate reduction to 30 kHz, a lowpass at +cutoff+ (a number or a
  # node, e.g. a knob), and a little tape saturation.  Velocity 0.75 (MIDI
  # 95) plays a slice as cut.
  def self.jungle_breaks_voice(midi, map: nil, cutoff: 16000, grit: 0.25, level: 1.6)
    map ||= jungle_sampler
    voice = map.sampler(midi) { |v, s| s * v.env(0.0005, 0.01, 1, 0.006, gm: false) * (v.velocity * (1 / 0.75)) }
    voice
      .filter(:lowpass, cutoff: 13000, quality: 0.6)
      .decimate(30000, mix: grit)
      .filter(:lowpass, cutoff: cutoff, quality: 0.9)
      .softclip(0.6, 0.98) * level
  end

  # Ride, shaker, crash (+source+: a grid Kit with :ride, :maracas, :crash
  # rows, or MIDI with tr808's GM note map), highpassed at 300 Hz.
  def self.jungle_perc(source, ride: { decay: 0.9, tone: 0.7, level: 0.4 }, shaker: { decay: 0.05, level: 0.3 }, accent: 6.db)
    tr808(
      source,
      cymbal: ride,
      maracas: shaker,
      rimshot: { level: 0.2 }, accent: accent
    ).filter(:highpass, cutoff: 300, quality: 0.7)
  end

  # The sub: a sine with a little 2nd harmonic, gliding between legato
  # notes, mono.  The oscillators run free (.free): resetting their phase
  # at a note-on while the last note's release still rang clicked
  # (patches-2, 2026-10-13); the same for the Reese and the flute.
  def self.jungle_sub_voice(midi, level: 0.3, glide: 0.05)
    synth(midi, voices: 1) { |v|
      p = v.hz.glide(glide, legato: true)
      (p.sine.free + p.transpose(12).sine.free * 0.15) * v.env(0.006, 0.2, 0.85, 0.12, gm: false).legato
    } * level
  end

  # The Reese: two saws +detune+ apart, an octave sine under them, a
  # lowpass breathing between +low+ and +high+ Hz on a 2-bar LFO.
  def self.jungle_reese_voice(midi, level: 0.32, detune: 16.cents, low: 260, high: 700)
    synth(midi, voices: 1) { |v|
      p = v.hz.glide(0.06, legato: true)
      saws = p.unison(2, detune: detune, phase: 0.0) { |c, _i| c.saw.free }
      breath = 1.bar.hz.transpose(-12).lfo.at(low..high)
      body = saws.lp4(breath, resonance: 0.2)
      (body * 0.9 + p.sine.free * 0.6) * v.env(0.02, 0.3, 0.9, 0.15, gm: false).legato
    }.softclip(0.5, 0.95) * level
  end

  # The keys (an electric piano), in a hall (+hall+ wet) with a stereo
  # tremolo at +tremolo+ Hz.  +piano+ :tine (the default) plays the tine
  # piano from bin/synths/electric_pianos.rb (.tine_piano_voice; +bark+
  # 0.22 is its bark 1); :fm is the persona's own keys: a phase-modulated
  # sine whose index decays fast (the bark; +bark+ the index) and a faint
  # tine.  patches-4 (2026-10-13; the maintainer preferred the tine piano
  # to these keys on the Listening Bench); before, the keys were :fm.
  # +level+ is the same for both (the tine is trimmed to the FM keys'
  # loudness on the jungle template's stabs plus 5 dB: see
  # JUNGLE_KEYS_TINE_TRIM).
  def self.jungle_keys_voice(midi, level: 0.15, bark: 0.22, tremolo: 4.6, hall: 0.22, piano: :tine)
    if piano == :tine
      tine = tine_piano_voice(midi, bark: bark / 0.22, tremolo: 0.22, rate: tremolo)
      return tine.reverb(:hall, mix: hall) * (level * JUNGLE_KEYS_TINE_TRIM)
    end
    raise ArgumentError, "Unknown jungle keys piano #{piano.inspect} (:tine or :fm)" unless piano == :fm

    keys = synth(midi, voices: 8) { |v|
      p = v.hz
      index = v.env(0.001, 0.5, 0.15, 0.3, gm: false)
      tine = p.transpose(12 * Math.log2(7)).sine * v.env(0.0005, 0.08, 0, 0.05, gm: false) * 0.06
      (p.sine.pm(p.sine, index * bark) + tine) * v.env(0.002, 1.6, 0.35, 0.35, gm: false)
    }
    trem = tremolo.hz.lfo
    stereo(keys * (trem * 0.22 + 0.78), keys * (trem * -0.22 + 0.78)).reverb(:hall, mix: hall) * level
  end

  # The string pad: five saws per note +detune+ apart, slow attack, a
  # lowpass at +cutoff+, highpassed at 180 Hz, Juno chorus, hall.
  def self.jungle_pad_voice(midi, level: 0.085, cutoff: 2400, detune: 22.cents, hall: 0.35)
    pad = synth(midi, voices: 4) { |v|
      saws = v.hz.unison(5, detune: detune) { |c, _i| c.saw }
      saws.filter(:lowpass, cutoff: cutoff, quality: 0.6) * v.env(1.2, 1.0, 0.8, 1.8, gm: false)
    }
    pad.filter(:highpass, cutoff: 180, quality: 0.7).chorus(:juno12).reverb(:hall, mix: hall) * level
  end

  # The flute-ish lead: triangle and sine with a little bandpassed breath,
  # a delayed vibrato, a dotted-eighth echo (+send+ wet, a number or a
  # node; +feedback+) and a hall.
  def self.jungle_flute_voice(midi, send: 0.3, level: 0.17, feedback: 0.35, breath: 0.05)
    lead = synth(midi, voices: 1) { |v|
      p = v.hz.glide(0.04, legato: true).vibrato(5.2, depth: 15.cents, delay: 0.25)
      air = noise.filter(:bandpass, cutoff: 2600, quality: 1.2) * breath
      (p.triangle.free * 0.6 + p.sine.free * 0.5 + air) * v.env(0.04, 0.3, 0.8, 0.25, gm: false)
    }
    (lead * level).delay(1.n8.dotted, feedback: feedback, wet: send, dry: 1).reverb(:hall, mix: 0.25)
  end

  # The tine piano's trim in .jungle_keys_voice: +15.1 dB since patches-5
  # (2026-10-13; maintainer on genre :jungle with the tine keys: "Both
  # keys mix levels are too low now; need to bump them up"), 5 dB over
  # patches-4's +10.1 (which matched the FM keys' loudness on the stabs,
  # -24.8 vs -24.3 LUFS, but the tine's rounder stabs sat under the pad):
  # in genre :jungle the keys' bars now average -23..-26 dB RMS on the
  # stem (pad -24, flute -23; were -28..-31).  Memory Card's keys and the
  # :jungle_keys preset follow.
  JUNGLE_KEYS_TINE_TRIM = 3.2 * 5.db

  # The script's patches by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.jungle_patch(midi, patch = :keys, cutoff: 16000.0, echo: 0.3)
    case patch
    when :breaks then jungle_breaks_voice(midi, cutoff: cutoff.constant.named('cutoff'))
    when :sub then jungle_sub_voice(midi)
    when :reese then jungle_reese_voice(midi)
    when :keys then jungle_keys_voice(midi)
    when :pad then jungle_pad_voice(midi)
    when :flute then jungle_flute_voice(midi, send: echo.constant.named('echo'))
    when :perc then jungle_perc(midi)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.jungle_description(what)
    what = "90s jungle patch :#{what}" if what.is_a?(Symbol)
    "#{what} from bin/synths/jungle.rb, " \
      'first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, ' \
      'for the song "Memory Card" (bin/songs/memory_card.rb) ' \
      'in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { jungle_description(p.patch) },
      patch: [:keys, Symbol, '-p', 'Patch to play', [:breaks, :sub, :reese, :keys, :pad, :flute, :perc]],
      cutoff: [16000.0, Float, '-c', 'Breaks lowpass in Hz', 200.0..16000.0],
      echo: [0.3, Float, '-e', 'Flute echo send 0..1', 0.0..1.0],
    ) { |midi, p|
      jungle_patch(midi, p.patch, cutoff: p.cutoff, echo: p.echo)
    }
  end
end
