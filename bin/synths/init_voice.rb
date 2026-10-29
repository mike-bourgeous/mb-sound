#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# The init voice: the blank patch to start a sound from (sound-design-2,
# 2026-10-29; the maintainer: "Init, based on 2osc morph with optional
# am/fm/sync, like sq80+mini dx7").  Copy it and edit it: every number is a
# knob (a preset param; on a track, the knob :"lead/cutoff" and so on).
#
# Signal path, per voice:
#
#     OSC1 (wave1 morph) ---------------------------+-- mix --> lp4 --> amp
#       |  FM (fm: OSC1 bends OSC2's frequency)      |    (cutoff, reso,
#       |  AM (am: OSC1 multiplies OSC2)             |     filter env)
#       |  sync (OSC2 restarts with OSC1)            |
#     OSC2 (wave2 morph, tune2 semitones) ----------+
#
# - The oscillators read the library's :basic_norm wavetable, scanning sine
#   (0), triangle (1/3), square (2/3), saw (1): one band-limited
#   oscillator per morph (mipmapped tables pick their levels by pitch, so
#   any scan position and FM stay clean as far as the levels allow), every
#   frame as loud as the saw (normalize: :loudness), so the level holds
#   while the wave knob moves.  Crossfading separate PolyBLEP tones would
#   cost an oscillator per shape, and Tone#pwm/#skew morphs only one pair.
# - FM is linear through-zero FM of OSC2's frequency by OSC1, with a
#   DX7-style index: fm 1 deviates OSC2 by OSC1's frequency, so the
#   sidebands stay the same at every note (frequency rather than phase
#   modulation so it combines with sync; for sines the two differ only by
#   the modulator's phase).
# - AM: OSC2 times (1 - am + am * OSC1); am 1 is ring modulation.
# - sync (0 or 1) hard-syncs OSC2 to OSC1, read when the voice builds
#   (Tone#sync's enabled:): off costs nothing, and on a track the knob
#   rebuilds the track when turned.  Sweep tune2 up for the classic sync
#   lead.
# - fm, am, and sync are off by default; with all three off the voice is
#   two detuned saws.
#
# Usage:
#     bin/synths/init_voice.rb                       # live MIDI
#     bin/synths/init_voice.rb --sync 1 --tune2 12 song.mid lead.flac
#
# Snippets (bin/sound.rb):
#     design :lead                                    # a new track on the init voice
#     bg :lead, preset(:init, midi: seq(A3, C4, E4, G4).n8.loop, fm: 1.5, wave2: 0)
#     bg :lead, preset(:init, midi: seq(A2, A2, C3, E3).n8.loop, sync: 1, tune2: 14, cutoff: 3000)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The init voice's knobs (sound-design-2): name => [default, range,
  # description].  The defaults are the blank patch: two saws 7 cents
  # apart into a gently opening four-pole.  bin/save_presets.rb saves them
  # as the :init preset's params.
  INIT_KNOBS = {
    wave1: [1.0, 0.0..1.0, 'OSC1 wave: sine 0, triangle 0.33, square 0.67, saw 1 (morphs between)'],
    wave2: [1.0, 0.0..1.0, 'OSC2 wave: sine 0, triangle 0.33, square 0.67, saw 1 (morphs between)'],
    tune2: [0.07, -24.0..24.0, 'OSC2 pitch in semitones from OSC1 (0.07: 7 cents; sweep it with sync on)'],
    mix: [0.5, 0.0..1.0, 'OSC1 0 .. OSC2 1'],
    fm: [0.0, 0.0..4.0, 'FM index: OSC1 modulates OSC2\'s frequency (DX7-style: the same sidebands at every note), 0: off'],
    am: [0.0, 0.0..1.0, 'AM: OSC1 multiplies OSC2 (1: ring modulation), 0: off'],
    sync: [0, 0..1, 'Hard sync of OSC2 to OSC1, 0 off or 1 on (read when the voice builds: turning it rebuilds the track)'],
    cutoff: [1200.0, 20.0..20000.0, 'Filter cutoff in Hz at C4 before the envelope (keytracked half)'],
    reso: [0.2, 0.0..1.0, 'lp4 resonance 0..1'],
    fenv: [2.0, 0.0..6.0, 'Filter envelope amount in octaves'],
    fdecay: [0.4, 0.001..10.0, 'Filter envelope decay in seconds'],
    attack: [0.005, 0.001..10.0, 'Amplitude attack in seconds'],
    decay: [0.3, 0.001..10.0, 'Amplitude decay in seconds'],
    sustain: [0.7, 0.0..1.0, 'Amplitude sustain level 0..1'],
    release: [0.3, 0.001..10.0, 'Amplitude release in seconds (the filter envelope\'s too)'],
    glide: [0.0, 0.0..2.0, 'Glide between notes in seconds, 0: off'],
  }.freeze

  # The output level: about -20.3 LUFS through the default master on a
  # held-note lead phrase (InitVoice measurement in the script's spec),
  # like the library's other synth presets.
  INIT_VOICE_LEVEL = 1.8

  # The init voice (see the header) playing +midi+ (Notes, a Clip, a MIDI
  # file, or a Stream), with +voices+ voices.  Each of INIT_KNOBS is a
  # named Constant at its value (or the value given), so --save makes it a
  # param.
  def self.init_voice(midi, voices: 8, **knobs)
    bad = knobs.keys - INIT_KNOBS.keys
    raise ArgumentError, "Unknown init voice knob#{'s' if bad.length > 1} #{bad.join(', ')} (#{INIT_KNOBS.keys.join(', ')})" unless bad.empty?
    k = INIT_KNOBS.to_h { |name, (default, _, _)|
      v = knobs[name].nil? ? default : knobs[name]
      [name, (name == :sync ? v.to_i : v.to_f).constant.named(name.to_s)]
    }
    wave1, wave2, tune2, mix, fm, am, sync = k.values_at(:wave1, :wave2, :tune2, :mix, :fm, :am, :sync)
    cutoff, reso, fenv, fdecay = k.values_at(:cutoff, :reso, :fenv, :fdecay)
    attack, decay, sustain, release, glide = k.values_at(:attack, :decay, :sustain, :release, :glide)

    synth(midi, voices: voices) { |v|
      f = v.hz.glide(glide)
      osc1 = f.wavetable(:basic_norm, scan: wave1).named('osc1')
      osc2 = f.transpose(tune2).wavetable(:basic_norm, scan: wave2).fm(osc1 * v.freq * fm).sync(osc1, enabled: sync)
        .gain(1 - am + osc1 * am).named('osc2')
      oscs = osc1 * (1 - mix) + osc2 * mix
      cut = cutoff * 2 ** ((v.number - 60) / 24.0) * v.filter_env(0.002, fdecay, 0, release, depth: fenv)
      amp = v.amp_env(attack, decay, sustain, release)
      oscs.lp4(cut, resonance: reso) * amp * INIT_VOICE_LEVEL
    }
  end

  # The script's patches by name (one: :init), as the other synth scripts
  # have (bin/save_presets.rb's spec plays each preset against its patch).
  def self.init_voice_patch(midi, patch = :init, **knobs)
    raise ArgumentError, "Unknown init voice patch #{patch.inspect} (init)" unless patch == :init
    init_voice(midi, **knobs)
  end

  # The preset's description (--save writes it into the document).
  def self.init_voice_description(_p = nil)
    'Init: the blank voice to start a sound from: two morphing oscillators (sine, triangle, square, saw), ' \
      'a mix, optional FM, AM, and hard sync of OSC2 by OSC1 (each off by default), a four-pole lowpass with ' \
      'its envelope, an amp ADSR, and glide; every number a knob (from bin/synths/init_voice.rb, sound-design-2, 2026-10-29)'
  end

  if main_script?(__FILE__)
    synth_script(
      description: method(:init_voice_description),
      patch: [:init, Symbol, '-p', 'Patch to play (one for now: the blank voice)', [:init]],
      **INIT_KNOBS.to_h { |name, (default, range, description)| [name, [default, default.class, description, range]] },
      voices: [8, Integer, 'Voices', 1..16],
    ) { |midi, p|
      init_voice_patch(midi, p.patch, voices: p.voices, **INIT_KNOBS.keys.to_h { |n| [n, p[n]] })
    }
  end
end
