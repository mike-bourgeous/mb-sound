#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Three single-cycle wavetable voices through a resonant 4-pole lowpass:
# digital brass, a resonant organ, and a square bass, playable from MIDI.
#
# Where they came from: the research prototype voice of 2026-10-06 (branch
# research-sq80, research/sq80/prototype/sq80_voice.rb), a separate offline
# engine that the maintainer kept coming back to on the Bench ("square bass
# grit"; protos-1, 2026-10-23: "it's the overall patch that works, not
# necessarily the 8-bit or grit").  Rebuilt here from library nodes: the
# prototype's additive tables as Wavetables (original recipes, nothing from
# any ROM), its linear L/T envelopes, its filter (lp4 is the prototype's
# ladder: same zero-delay-feedback cascade and 0.375 passband compensation,
# played at tuning: :hardware, which is the prototype's cutoff mapping),
# drive, key tracking, and levels.
#
# Patches (-p):
#   digibrass    brass stabs and swells: a saw and a bright formant wave
#                7 cents apart plus a short noise-and-chirp attack, a
#                filter envelope opening 3.5 octaves, slight vibrato
#   organ_reso   an organ through a resonant, nearly closed filter that
#                blips open on each key: drawbar harmonics 1-8 plus SYNTH 3
#                (equal harmonics 1, 2, 3, then primes to 23) an octave up
#   square_bass  a plucked bass: a square plus a saw an octave down, the
#                filter plucked 4 octaves by a fast envelope
#
# --grit (0..1, also each preset's grit param) blends in the prototype's
# "DOC" grit: the oscillators held at the Ensoniq DOC's 38,461.5 Hz, aliasing
# on purpose (1 is the prototype's grit; see WAVE_VOICE_DOC_RATE).  Each
# patch is also a preset: `preset :square_bass, midi: midi, grit: 1`.
#
# Usage:
#     bin/synths/wave_voices.rb                          # live MIDI, digibrass
#     bin/synths/wave_voices.rb -p square_bass --grit 1 song.mid bass.flac
#
# Snippets (bin/sound.rb):
#     bpm 100
#     bg :bass, preset(:square_bass, midi: seq(A1, A1, R, A2, A1, R, G1, E1).n8.loop)
#     bg :organ, preset(:organ_reso, midi: (seq(A3, F3, C4, G3).n2 & seq(C4, A3, E4, B3).n2 & seq(E4, C4, G4, D4).n2).loop)
#     bg :brass, preset(:digibrass, midi: seq([A3, C4, E4].n8, R.n8, R.n4, [G3, C4, E4].n8, R.n8, [F3, A3, C4].n4).loop)
#     bg :keys, preset(:organ_reso, midi: midi, grit: 1)    # live keyboard

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The DOC's output rate in the ESQ-1 and SQ-80 (8 MHz / 208), where
  # --grit holds the oscillators (38,461.54 Hz, rounded).  The prototype's
  # grit also read 256-sample 8-bit tables without interpolation, but
  # measured after the filter the hold is all of it: the inharmonic floor
  # of a held organ_reso A3 is -30.8 dB with those tables, -30.8 with the
  # clean tables held (the prototype's -31.4, clean -62.7), so the voices
  # keep their clean tables (protos-1).
  WAVE_VOICE_DOC_RATE = 38461.5

  # The prototype's bright "digital formant" wave: a 1/n slope with a bump
  # around harmonic 9 (0.6 / n + 0.7 exp(-((n - 9) / 2.5)^2), 40
  # harmonics, as the prototype's tables had for its higher notes).
  WAVE_VOICE_FORMANT = (1..40).map { |n| (0.6 / n + Math.exp(-((n - 9.0) / 2.5)**2) * 0.7).round(3) }.freeze

  # Drawbar organ harmonics 1, 2, 3, 4, 6, 8 (an original mix).
  WAVE_VOICE_ORGAN = [1, 0.8, 0.6, 0.5, 0, 0.35, 0, 0.3].freeze

  # SYNTH 3 from the SQ-80 manual's description: harmonics 1, 2, 3 and
  # primes to 23 at equal levels.
  WAVE_VOICE_SYNTH3 = (1..23).map { |n| [1, 2, 3, 5, 7, 11, 13, 17, 19, 23].include?(n) ? 1 : 0 }.freeze

  # The patches: oscillators (+:wave+ a library table name or harmonic
  # amplitudes, +:phase+ the starting phase in cycles, +:semitones+
  # including the prototype's cents, +:level+),
  # +:attack+ (the noise-and-chirp transient's level, or nil), the filter
  # (+:cutoff+ Hz at C4 before the envelope, +:reso+ lp4 resonance,
  # +:keytrack+ octaves per octave, +:env_octaves+, +:drive+), the filter
  # and amplitude envelopes ([level, seconds] segments, linear, released
  # after the third), +:vibrato+ ([Hz, semitones] or nil), +:voices+, and the
  # output +:level+ (about -20.3 LUFS through the default master on a
  # phrase in each patch's role, like the library's other synth presets).
  #
  # The prototype's saws were sine-phase harmonics (+1/n each): a falling
  # ramp starting at its top, which is the library saw half a cycle on and
  # upside down (phase 0.5, a negative level).  Through the drive the saw's
  # phase against the other oscillator matters: the library saw's own
  # phase measured 0.6-1.2 dB of spectral shape and 0.8-1.4 dB of
  # envelope away from the prototype's renders, this 0.1-0.5 dB.
  WAVE_VOICES = {
    digibrass: {
      description: 'Digital brass for stabs and swells: a saw and a bright formant wave 7 cents apart plus a ' \
                   'noise-and-chirp attack, a resonant 4-pole opening 3.5 octaves on each note, slight vibrato',
      oscs: [
        { wave: :saw, phase: 0.5, semitones: 0, level: -0.6 },
        { wave: WAVE_VOICE_FORMANT, semitones: 0.07, level: 0.5 },
      ],
      attack: 0.5,
      cutoff: 500.0, reso: 0.3717, keytrack: 0.5, env_octaves: 3.5, drive: 1.5,
      filter_env: [[1.0, 0.03], [0.55, 0.25], [0.35, 0.8], [0.0, 0.4]],
      amp_env: [[1.0, 0.01], [0.85, 0.2], [0.75, 0.3], [0.0, 0.45]],
      vibrato: [5.5, 0.0346],
      voices: 8,
      level: 2.58,
    },
    organ_reso: {
      description: 'Resonant organ for chords and comping: drawbar harmonics plus SYNTH 3 an octave up through a ' \
                   'resonant, nearly closed 4-pole that blips open on each key',
      oscs: [
        { wave: WAVE_VOICE_ORGAN, semitones: 0, level: 0.7 },
        { wave: WAVE_VOICE_SYNTH3, semitones: 11.96, level: 0.3 },
      ],
      attack: nil,
      cutoff: 900.0, reso: 0.6401, keytrack: 1.0, env_octaves: 1.5, drive: 2.0,
      filter_env: [[1.0, 0.005], [0.3, 0.15], [0.2, 0.3], [0.0, 0.3]],
      amp_env: [[1.0, 0.004], [1.0, 0.01], [1.0, 0.01], [0.0, 0.25]],
      vibrato: nil,
      voices: 8,
      level: 1.49,
    },
    square_bass: {
      description: 'Plucked square bass for bass lines: a square plus a saw an octave down, a resonant 4-pole ' \
                   'plucked 4 octaves open by a fast envelope',
      oscs: [
        { wave: :square, semitones: 0, level: 0.8 },
        { wave: :saw, phase: 0.5, semitones: -11.97, level: -0.5 },
      ],
      attack: nil,
      cutoff: 150.0, reso: 0.481, keytrack: 0.3, env_octaves: 4.0, drive: 2.5,
      filter_env: [[1.0, 0.002], [0.15, 0.18], [0.0, 0.2], [0.0, 0.1]],
      amp_env: [[1.0, 0.002], [0.8, 0.3], [0.7, 0.3], [0.0, 0.12]],
      vibrato: nil,
      voices: 4,
      level: 3.08,
    },
  }.freeze

  # A wavetable voice (see the header) playing +midi+ (Notes, a Clip, a
  # MIDI file, or a Stream).  +grit+ (0..1, or true/false) blends in the
  # DOC-rate hold of the oscillators (a named Constant, a preset param);
  # +cutoff+ (Hz at C4) and +reso+ (0..1) default to the patch's and
  # become named Constants (preset params), as does +level+ when given.
  def self.wave_voice(midi, patch = :digibrass, grit: 0.0, cutoff: nil, reso: nil, voices: nil, level: nil)
    s = WAVE_VOICES.fetch(patch) { raise ArgumentError, "Unknown wave voice #{patch.inspect} (#{WAVE_VOICES.keys.join(', ')})" }
    cutoff = (cutoff || s[:cutoff]).to_f.constant.named('cutoff')
    reso = (reso || s[:reso]).to_f.constant.named('reso')
    gain = level ? level.to_f.constant.named('level') : s[:level]
    grit = { true => 1.0, false => 0.0 }.fetch(grit, grit).to_f.constant.named('grit')
    tables = s[:oscs].map { |o| wavetable_of(o[:wave]) }

    synth(midi, voices: voices || s[:voices]) { |v|
      f = s[:vibrato] ? v.hz.vibrato(s[:vibrato][0], depth: s[:vibrato][1]) : v.hz
      oscs = s[:oscs].each_with_index.map { |o, i|
        p = o[:semitones] == 0 ? f : f.transpose(o[:semitones])
        osc = p.wavetable(tables[i])
        osc = osc.with_phase(o[:phase]) if o[:phase]
        osc * o[:level]
      }
      mix = oscs.reduce(:+)
      mix = mix.decimate(WAVE_VOICE_DOC_RATE, mix: grit)
      if s[:attack]
        # 40 ms of lowpassed noise and a falling 1.8 kHz chirp at each note
        hiss = noise.filter(:lowpass, cutoff: 3300, quality: 0.5) * v.env(0, 0.04, 0, 0.04, curve: [0, 58, 58]).no_velocity
        sweep = v.env(0, 0.04, 0, 0.04, curve: 0).no_velocity * 720 + 1080
        chirp = sweep.tone.sine.reset(v.trigger) * v.env(0, 0.012, 0, 0.012, curve: [0, 52, 52]).no_velocity
        mix += (hiss * 1.6 + chirp * 0.8) * s[:attack]
      end
      fenv = v.env(s[:filter_env], release_at: 3, curve: 0).no_velocity
      cut = cutoff * 2 ** ((v.number - 60) / (12.0 / s[:keytrack]) + fenv * s[:env_octaves])
      amp = v.env(s[:amp_env], release_at: 3, curve: 0, sensitivity: 0.5..1.0)
      out = (mix * 0.35).lp4(cut, resonance: reso, drive: s[:drive], tuning: :hardware) * amp
      gain == 1 ? out : out * gain
    }
  end

  # Where the patches came from, for preset descriptions (--save writes
  # it into the document): +what+ is the patch (a Symbol) or a phrase.
  def self.wave_voices_description(what)
    if what.is_a?(Symbol)
      what = "Wave voice :#{what}: #{WAVE_VOICES.fetch(what)[:description]}; grit 0..1 holds the oscillators at the Ensoniq DOC's 38.46 kHz"
    end
    "#{what} (from bin/synths/wave_voices.rb: the research-sq80 prototype voice of 2026-10-06, rebuilt from library nodes in protos-1, 2026-10-23)"
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { wave_voices_description(p.patch) },
      patch: [:digibrass, Symbol, '-p', 'Patch to play', WAVE_VOICES.keys],
      grit: [0.0, Float, '-G', 'Grit 0..1: the oscillators held at the DOC\'s 38.46 kHz, aliasing (1: the prototype\'s grit)', 0.0..1.0],
      cutoff: [nil, Float, 'Filter cutoff in Hz at C4 before the envelope (digibrass 500, organ_reso 900, square_bass 150)', 20.0..10000.0],
      reso: [nil, Float, 'lp4 resonance 0..1 (digibrass 0.37, organ_reso 0.64, square_bass 0.48)', 0.0..1.0],
      voices: [nil, Integer, 'Voices (default: the patch\'s)', 1..16],
    ) { |midi, p|
      wave_voice(midi, p.patch, grit: p.grit, cutoff: p.cutoff, reso: p.reso, voices: p.voices)
    }
  end
end
