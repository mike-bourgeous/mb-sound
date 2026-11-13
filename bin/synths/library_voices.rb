#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Library voices: one playable instrument per synthesis approach mb-sound
# has (library-voices-1, 2026-11-13; the maintainer: "build some sample
# library voices based on the different design options that already exist
# (am, fm/pm, etc.)").  Each patch is also a library preset (bin/save_presets.rb
# saves it with its knobs as params, its tags, and its description), so
# `L.inst.fm_ep`, `track :keys, :fm_ep`, and `preset :fm_ep, midi: clip,
# index: 3` all play it, and on a track every knob is a track knob
# (:"keys/index").
#
# Patches (-p), by approach:
#   ring_bell     AM and ring modulation: a sine times a sine at an
#                 inharmonic ratio, the ring fading as the note decays
#   fm_ep         two-operator phase modulation: an electric piano whose
#                 index falls after the strike, plus a short high tine
#   fm_bass       operator feedback (fm_feedback): a sine that turns
#                 saw-like as its feedback envelope opens, with a sub sine
#   sync_lead     hard sync: a saw restarted by the note, its own pitch
#                 swept down by an envelope (the classic sync lead)
#   pwm_strings   pulse width modulation: two pulses whose widths drift on
#                 slow LFOs, a gentle lowpass, a Juno-style chorus
#   scan_pad      wavetable scanning: a table from a sine to a saw through
#                 hollow and vocal frames, scanned by an envelope and an LFO
#   partial_keys  additive: sixteen harmonics, each with its own decay
#                 (the high ones die first), brightness and odd/even knobs
#   ladder_lead   subtractive: two detuned saws and a square sub through the
#                 four-pole ladder (lp4) with its envelope, glide
#   supersaw      unison: seven detuned saws spread in stereo
#   breath_vowel  formant: a saw and breath noise through vowel formants,
#                 the vowel morphing on a knob, delayed vibrato
#   noise_bands   noise-band harmonics: white noise through bandpasses at the
#                 note's harmonics (narrow: pitched, wide: airy)
#   bowed_glass   modal: noise bowing the glass resonator, sustained for as
#                 long as the key is held
#   nylon_pluck   Karplus-Strong: the plucked string of bin/synths/pluck.rb
#                 (a feedback loop one period long), dry
#   cheby_bass    waveshaping: a sine through Chebyshev polynomials driven
#                 by an envelope, so the harmonics follow the note's level
#   grain_pad     granular: grains of a bounced oscillator tone, tuned to the
#                 note, spread in stereo
#
# The voices use library nodes only (no engine of their own).  Each output
# sits near -12 LUFS before the master (about -22 LUFS through its default
# -10 dB) on a phrase in its role, with its true peak under 0 dBTP.
#
# Usage:
#     bin/synths/library_voices.rb -p fm_ep                       # live MIDI
#     bin/synths/library_voices.rb -p sync_lead --sweep 5 song.mid lead.flac
#
# Snippets (bin/sound.rb):
#     bpm 110
#     play L.inst.fm_ep                                  # the demo phrase
#     play L.inst.fm_ep.(seq(A3, C4, E4, G4).n8, index: 3)
#     bg :bass, L.inst.fm_bass.(seq(A1, A1, R, A2, A1, R, G1, E1).n8.loop)
#     track :lead, seq(A4, C5, E5, D5).n4.loop, :sync_lead; turn :"lead/sweep", 0 => 1, 2.bars => 6

require 'bundler/setup'
require 'mb-sound'
require_relative 'pluck' # (pluck_voice; guarded by main_script?)

module MB::Sound
  # A wavetable from a sine through hollow (odd harmonics), vocal (a bump
  # around the 6th harmonic), and bright (1/n with the even ones lifted)
  # frames to a saw, for scan_pad.
  LIBRARY_VOICE_SCAN_FRAMES = [
    :sine,
    [1, 0, 0.45, 0, 0.25, 0, 0.12, 0, 0.06],
    (1..24).map { |n| (0.5 / n + 0.8 * Math.exp(-((n - 6.0) / 2.0)**2)).round(3) },
    (1..32).map { |n| ((n.even? ? 1.4 : 1.0) / n).round(3) },
    :saw,
  ].freeze

  # The patches: +:approach+ (a few words), +:about+ (the preset's
  # description), +:tags+, +:voices+, +:knobs+ ({ name => [default, range,
  # description] }: the preset's params), +:level+ (the output gain), and
  # +:build+, a Proc of the voice (a Notes lane) and the knobs (a Hash of
  # nodes or numbers by name) giving the voice's signal before the level.
  LIBRARY_VOICES = {
    ring_bell: {
      approach: 'AM / ring modulation',
      about: 'Ring-modulated bell: a sine times a sine at an inharmonic ratio (sum and difference tones), ' \
             'the ring fading toward a plain sine as the note decays',
      tags: %i[am ring_mod metallic keys],
      voices: 8,
      knobs: {
        ratio: [3.53, 0.25..8.0, 'Modulator frequency over the note\'s (3.53: bell-like; whole numbers: harmonic)'],
        ring: [1.0, 0.0..1.0, 'Modulation: 0 a plain sine, 0.5 AM, 1 ring modulation (at the strike; it fades with ring_decay)'],
        ring_decay: [0.8, 0.01..10.0, 'Seconds the ring takes to fade toward the plain sine'],
        decay: [2.5, 0.05..10.0, 'Amplitude decay in seconds'],
        release: [0.6, 0.01..5.0, 'Release in seconds'],
      },
      level: 0.45,
      build: ->(v, k) {
        car = v.hz.sine
        mod = (v.freq * k[:ratio]).tone.sine
        depth = k[:ring] * v.env(0.0, k[:ring_decay], 0.25, k[:release], gm: false).no_velocity
        bell = car * (1 - depth + mod * depth)
        bell * v.env(0.002, k[:decay], 0.0, k[:release], gm: false)
      },
    },

    fm_ep: {
      approach: 'FM / PM (two operators)',
      about: 'Two-operator FM electric piano: a sine phase-modulated by a sine whose index falls after the strike ' \
             '(harder notes brighter), plus a short high tine for the bark',
      tags: %i[fm pm electric_piano keys],
      voices: 8,
      knobs: {
        index: [2.2, 0.0..10.0, 'Modulation index in radians at the strike (brightness)'],
        ratio: [1.0, 0.5..8.0, 'Modulator frequency over the note\'s (1: harmonic; 3.5: bell-like)'],
        tine: [0.6, 0.0..2.0, 'Level of the short high tine (14x) at the strike'],
        decay: [2.0, 0.05..10.0, 'Amplitude decay in seconds'],
        release: [0.35, 0.01..5.0, 'Release in seconds'],
      },
      level: 0.41,
      dc_block: 20,
      build: ->(v, k) {
        idx = k[:index] * v.env(0.001, 0.9, 0.2, k[:release], gm: false)
        tine = (v.freq * 14).tone.sine * k[:tine] * v.env(0.0, 0.06, 0, 0.05, gm: false)
        mod = (v.freq * k[:ratio]).tone.sine * idx + tine
        v.hz.sine.pm(mod.radians) * v.env(0.002, k[:decay], 0.0, k[:release], gm: false)
      },
    },

    fm_bass: {
      approach: 'FM operator feedback',
      about: 'Feedback FM bass: a sine operator fed back into its own phase, turning saw-like as the feedback ' \
             'envelope opens on each note, with a sine an octave down',
      tags: %i[fm feedback dx bass],
      voices: 2,
      knobs: {
        feedback: [1.2, 0.0..1.8, 'Operator feedback in radians at the strike (0: a sine; past 1.5: buzzy)'],
        hold: [0.3, 0.0..1.0, 'Feedback kept while the note holds, as a share of the strike\'s'],
        fdecay: [0.25, 0.01..5.0, 'Seconds the feedback takes to fall to its held share'],
        sub: [0.5, 0.0..1.0, 'Level of the sine an octave down'],
        release: [0.08, 0.005..2.0, 'Release in seconds'],
      },
      level: 0.6,
      dc_block: 20,
      build: ->(v, k) {
        fb = k[:feedback] * v.env(0.001, k[:fdecay], k[:hold], k[:release], gm: false).no_velocity
        op = v.hz.fm_feedback(fb.radians)
        sub = v.hz.transpose(-12).sine * k[:sub]
        (op + sub) * v.env(0.002, 0.6, 0.8, k[:release], gm: false)
      },
    },

    sync_lead: {
      approach: 'hard sync',
      about: 'Hard-sync lead: a saw restarted by the note\'s cycle, its own pitch swept down from above by an ' \
             'envelope on each note, through a gentle lowpass, with glide and delayed vibrato',
      tags: %i[sync saw lead],
      voices: 1,
      knobs: {
        sync: [1.5, 1.0..8.0, 'The synced saw\'s pitch over the note\'s once the sweep has fallen (1: no sync sound)'],
        sweep: [3.0, 0.0..8.0, 'How far above that the sweep starts (in the same ratio units)'],
        sweep_decay: [0.35, 0.01..5.0, 'Seconds the sweep takes to fall'],
        cutoff: [5000.0, 200.0..18000.0, 'Lowpass cutoff in Hz'],
        glide: [0.04, 0.0..1.0, 'Glide between legato notes in seconds'],
      },
      level: 0.55,
      dc_block: 20,
      build: ->(v, k) {
        f = v.hz.glide(k[:glide], legato: true).vibrato(5.2, depth: 0.15)
        ratio = k[:sync] + k[:sweep] * v.env(0.0, k[:sweep_decay], 0, 0.1, gm: false).no_velocity.legato
        saw = f.ramp.sync(ratio: ratio)
        saw.lp4(k[:cutoff], resonance: 0.1) * v.env(0.004, 0.3, 0.85, 0.12, gm: false).legato
      },
    },

    pwm_strings: {
      approach: 'PWM',
      about: 'PWM strings: two pulses a few cents apart, their widths drifting on slow LFOs, through a gentle ' \
             'keytracked lowpass and a Juno-style chorus (stereo)',
      tags: %i[pwm pulse strings pad analog],
      voices: 8,
      knobs: {
        width: [0.5, 0.05..0.95, 'Pulse width at the LFOs\' center (0.5: square)'],
        depth: [0.3, 0.0..0.45, 'How far the LFOs move the widths'],
        rate: [0.6, 0.05..8.0, 'LFO rate in Hz (the second pulse\'s LFO runs 0.73 times as fast)'],
        cutoff: [2400.0, 200.0..12000.0, 'Lowpass cutoff in Hz at C4 (keytracked half)'],
        attack: [0.35, 0.001..5.0, 'Attack in seconds'],
        release: [0.9, 0.01..8.0, 'Release in seconds'],
      },
      level: 0.18,
      chorus: :juno2,
      build: ->(v, k) {
        a = v.hz.pwm(k[:width] + k[:depth] * k[:rate].tone.sine.lfo).square
        b = v.hz.transpose(0.08).pwm(k[:width] + k[:depth] * (k[:rate] * 0.73).tone.sine.lfo.with_phase(0.3)).square
        cut = k[:cutoff] * 2 ** ((v.number - 60) / 24.0)
        ((a + b) * 0.5).lp4(cut, resonance: 0.05) * v.env(k[:attack], 0.5, 0.85, k[:release], gm: false)
      },
    },

    scan_pad: {
      approach: 'wavetable scanning',
      about: 'Wavetable pad: a table from a sine through hollow, vocal, and bright frames to a saw, scanned ' \
             'forward by a slow envelope on each note and back and forth by an LFO',
      tags: %i[wavetable scan pad evolving],
      voices: 8,
      knobs: {
        scan: [0.2, 0.0..1.0, 'Table position at the start of a note (0 sine .. 1 saw)'],
        sweep: [0.5, -1.0..1.0, 'How far the envelope scans over swell seconds'],
        swell: [3.0, 0.01..10.0, 'Seconds the envelope takes to scan'],
        wobble: [0.12, 0.0..0.5, 'LFO scan depth'],
        rate: [0.25, 0.01..8.0, 'LFO rate in Hz'],
        release: [1.2, 0.01..8.0, 'Release in seconds'],
      },
      level: 0.4,
      build: ->(v, k) {
        table = wavetable_of(*LIBRARY_VOICE_SCAN_FRAMES, normalize: :loudness)
        pos = (k[:scan] + k[:sweep] * v.env(k[:swell], 0, 1, k[:release], gm: false).no_velocity + k[:wobble] * k[:rate].tone.sine.lfo).aclip(0, 1)
        osc = v.hz.wavetable(table, scan: pos) + v.hz.transpose(0.1).wavetable(table, scan: pos)
        osc * 0.5 * v.env(0.4, 0.8, 0.8, k[:release], gm: false)
      },
    },

    partial_keys: {
      approach: 'additive',
      about: 'Additive keys: sixteen harmonics with levels falling by a brightness ratio, each decaying on its own ' \
             '(the high ones first), so notes start bright and mellow as they ring',
      tags: %i[additive harmonics keys],
      voices: 8,
      knobs: {
        bright: [0.62, 0.05..0.95, 'Each harmonic\'s level over the one below it'],
        odd: [0.3, 0.0..1.0, 'Even harmonics turned down: 0 all harmonics, 1 odd ones only (hollow)'],
        decay: [3.0, 0.05..10.0, 'The fundamental\'s decay in seconds (harmonic n decays n^0.8 times faster)'],
        release: [0.4, 0.01..5.0, 'Release in seconds'],
      },
      level: 0.31,
      build: ->(v, k) {
        spectrum = (1..16).map { |n|
          lvl = n == 1 ? 1.0 : k[:bright] ** (n - 1)
          lvl *= (1 - k[:odd]) if n.even?
          lvl * v.env(0.002, k[:decay] / (n**0.8), 0, k[:release], gm: false)
        }
        v.hz.harmonics(spectrum)
      },
    },

    ladder_lead: {
      approach: 'subtractive (lp4 ladder)',
      about: 'Ladder lead: two saws 9 cents apart and a square an octave down through the four-pole ladder ' \
             '(lp4), its cutoff opened by an envelope on each note; mono with glide',
      tags: %i[subtractive lp4 ladder analog lead],
      voices: 1,
      knobs: {
        cutoff: [700.0, 40.0..12000.0, 'Cutoff in Hz at C4 before the envelope (keytracked half)'],
        reso: [0.35, 0.0..1.0, 'Resonance 0..1'],
        fenv: [3.0, 0.0..6.0, 'Envelope amount in octaves'],
        fdecay: [0.5, 0.01..5.0, 'Envelope decay in seconds'],
        glide: [0.06, 0.0..1.0, 'Glide between legato notes in seconds'],
      },
      level: 1.0,
      build: ->(v, k) {
        f = v.hz.glide(k[:glide], legato: true)
        osc = f.saw + f.transpose(0.09).saw + f.transpose(-12).square * 0.6
        cut = k[:cutoff] * 2 ** ((v.number - 60) / 24.0 + k[:fenv] * v.env(0.003, k[:fdecay], 0.15, 0.2, gm: false).legato)
        (osc * 0.35).lp4(cut.aclip(20, 18000), resonance: k[:reso]) * v.env(0.003, 0.4, 0.8, 0.15, gm: false).legato
      },
    },

    supersaw: {
      approach: 'unison',
      about: 'Supersaw: seven detuned saws spread across the stereo field, a gentle lowpass, for chords and ' \
             'washes (stereo)',
      tags: %i[unison saw chords pad wide trance],
      voices: 8,
      knobs: {
        detune: [0.18, 0.0..1.0, 'Detune of the outer saws in semitones'],
        spread: [0.8, 0.0..1.0, 'Stereo spread of the copies'],
        mix: [0.8, 0.0..2.0, 'Side copies\' level against the center one'],
        cutoff: [6000.0, 200.0..18000.0, 'Lowpass cutoff in Hz'],
        attack: [0.02, 0.001..5.0, 'Attack in seconds'],
        release: [0.5, 0.01..8.0, 'Release in seconds'],
      },
      level: 0.25,
      build: ->(v, k) {
        saws = v.hz.unison(7, detune: k[:detune], spread: k[:spread], mix: k[:mix], detune_mode: :interp).saw
        saws.lp4(k[:cutoff], resonance: 0.05) * v.env(k[:attack], 0.4, 0.85, k[:release], gm: false)
      },
    },

    breath_vowel: {
      approach: 'formant',
      about: 'Breathy vowel: a saw and breath noise through vowel formants, the vowel morphing from oo through ' \
             'oh and ah to ee on a knob, with delayed vibrato and glide',
      tags: %i[formant vowel vocal breath lead],
      voices: 4,
      knobs: {
        vowel: [0.45, 0.0..1.0, 'Vowel: 0 oo, 0.33 oh, 0.67 ah, 1 ee (morphs between)'],
        breath: [0.35, 0.0..1.0, 'Breath noise level'],
        vibrato: [0.25, 0.0..1.0, 'Vibrato depth in semitones (it fades in over half a second)'],
        attack: [0.06, 0.001..3.0, 'Attack in seconds'],
        release: [0.3, 0.01..5.0, 'Release in seconds'],
        glide: [0.05, 0.0..1.0, 'Glide between legato notes in seconds'],
      },
      level: 0.22,
      build: ->(v, k) {
        vib = k[:vibrato] * v.env(0.5, 0, 1, 0.1, gm: false).no_velocity
        f = v.hz.glide(k[:glide], legato: true).vibrato(5.3, depth: vib)
        src = f.ramp + noise * k[:breath] * 1.5
        src.formant(:u, :o, :a, :i, morph: k[:vowel]) * v.env(k[:attack], 0.3, 0.9, k[:release], gm: false)
      },
    },

    noise_bands: {
      approach: 'noise-band harmonics',
      about: 'Noise-band pad: white noise through bandpasses at the note\'s first twelve harmonics (levels ' \
             'falling with the harmonic), pitched when the bands are narrow and airy when they are wide',
      tags: %i[noise bandpass harmonics pad airy],
      voices: 6,
      knobs: {
        focus: [40.0, 2.0..400.0, 'Band Q: higher is narrower and more pitched'],
        stretch: [1.0, 0.5..2.0, 'Spacing of the bands in harmonics (1: harmonic; others: inharmonic)'],
        attack: [0.5, 0.001..8.0, 'Attack in seconds'],
        release: [1.2, 0.01..8.0, 'Release in seconds'],
      },
      level: 0.85,
      build: ->(v, k) {
        bands = noise.bandpass_series(v.freq, count: 12, ratio: k[:stretch], quality: k[:focus], gain: ->(i) { 1.0 / (i + 1) })
        bands * k[:focus]**0.5 * v.env(k[:attack], 0.5, 0.9, k[:release], gm: false)
      },
    },

    bowed_glass: {
      approach: 'modal resonator (sustained)',
      about: 'Bowed glass: the glass resonator\'s modes excited by soft noise for as long as the key is held ' \
             '(a bow instead of a strike), swelling in and ringing out on release',
      tags: %i[modal resonator bowed pad],
      voices: 6,
      knobs: {
        bow: [1.0, 0.0..4.0, 'Bow pressure (the noise\'s level)'],
        tone: [3000.0, 200.0..16000.0, 'Lowpass on the bow noise in Hz (brighter excites higher modes)'],
        decay: [3.0, 0.2..12.0, 'Seconds the glass rings to -60 dB once the bow lets go (the preset\'s 8: a real glass)'],
        attack: [0.4, 0.001..5.0, 'Bow attack in seconds'],
        release: [0.3, 0.01..5.0, 'Bow release in seconds (the glass rings on after it)'],
      },
      level: 0.55,
      build: ->(v, k) {
        bow = noise.filter(:lowpass, cutoff: k[:tone], quality: 0.7) * k[:bow] * 0.01 * v.env(k[:attack], 0.0, 1.0, k[:release], gm: false)
        bow.resonate(:glass, v.freq, decay: k[:decay])
      },
    },

    nylon_pluck: {
      approach: 'Karplus-Strong (feedback loop)',
      about: 'Plucked string: a feedback loop one period long, excited by a noise pick and damped in the loop ' \
             '(bin/synths/pluck.rb\'s string), dry',
      tags: %i[karplus feedback string guitar pluck],
      voices: 6,
      knobs: {},
      settings: { sustain: 3.0, damping: 6.0, brightness: 12.0 },
      level: 0.5,
      dc_block: 20,
      build: ->(v, k) { pluck_voice(v, sustain: 3.0, damping: 6.0, brightness: 12.0) },
    },

    cheby_bass: {
      approach: 'waveshaping (Chebyshev)',
      about: 'Waveshaped bass: a sine through Chebyshev polynomials driven harder at the start of each note, so ' \
             'the upper harmonics follow the note\'s envelope (waveshaping synthesis)',
      tags: %i[waveshaping chebyshev bass],
      voices: 2,
      knobs: {
        drive: [1.0, 0.0..1.5, 'Drive at the strike (brightness; past 1 the curve\'s ends clip)'],
        hold: [0.4, 0.0..1.0, 'Drive kept while the note holds, as a share of the strike\'s'],
        ddecay: [0.3, 0.01..5.0, 'Seconds the drive takes to fall to its held share'],
        release: [0.08, 0.005..2.0, 'Release in seconds'],
      },
      level: 0.5,
      dc_block: 20,
      build: ->(v, k) {
        bright = v.env(0.001, k[:ddecay], 0, k[:release], gm: false).no_velocity
        drive = k[:drive] * (k[:hold] + (1 - k[:hold]) * bright)
        shaped = v.hz.sine.chebyshev(h1: 1, h2: 0.5, h3: -0.35, h4: -0.2, h5: 0.2, h6: 0.1, h7: -0.1, drive: drive)
        shaped * v.env(0.002, 0.5, 0.9, k[:release], gm: false)
      },
    },
    grain_pad: {
      approach: 'granular',
      about: 'Grain pad: a cloud of short grains read from a two-second tone bounced from oscillators (an A3 triangle ' \
             'with upper partials slightly off their harmonics, slowly beating), each grain tuned to the note, spread in stereo',
      tags: %i[granular grains cloud pad],
      voices: 6,
      knobs: {
        position: [0.35, 0.0..1.0, 'Where in the source tone the grains read (0..1)'],
        spread: [0.15, 0.0..0.5, 'Random spread of the read position (0..1 of the source)'],
        density: [30.0, 1.0..120.0, 'Grains per second per note'],
        size: [0.15, 0.01..1.0, 'Grain length in seconds'],
        detune: [0.08, 0.0..1.0, 'Random detune per grain in semitones'],
        attack: [0.6, 0.001..8.0, 'Attack in seconds'],
        release: [1.5, 0.01..8.0, 'Release in seconds'],
      },
      level: 0.38,
      # (bounced once per build, so the voices share one Sample; a saved
      # document keeps it as a FLAC asset in its bundle)
      prepare: -> {
        { source: bounce(2.seconds, root: A3, name: 'grain_source') {
          220.hz.triangle * 0.5 + 440.35.hz.sine * 0.25 + 659.4.hz.sine * 0.12 + 881.1.hz.sine * 0.06
        } }
      },
      build: ->(v, k) {
        cloud = v.grains(k[:source], density: k[:density], size: k[:size], position: k[:position], spread: k[:spread],
          pitch_spread: k[:detune], pan_spread: 0.7)
        cloud * v.env(k[:attack], 0.5, 0.9, k[:release], gm: false)
      },
    },
  }.freeze

  # Library voice +patch+ playing +midi+ (Notes, a Clip, a MIDI file, or a
  # Stream).  +knobs+ override the patch's (numbers, or nodes such as a
  # knob); each becomes a Constant named after it (a preset param when
  # saved).  +voices+ overrides the patch's polyphony.
  def self.library_voice(midi, patch = :fm_ep, voices: nil, **knobs)
    s = LIBRARY_VOICES.fetch(patch) { raise ArgumentError, "Unknown library voice #{patch.inspect} (#{LIBRARY_VOICES.keys.join(', ')})" }
    extra = knobs.keys - s[:knobs].keys
    raise ArgumentError, "Library voice #{patch} has no knob #{extra.map(&:inspect).join(', ')} (#{s[:knobs].keys.join(', ')})" unless extra.empty?
    k = s[:knobs].to_h { |name, (default, _range, _description)|
      value = knobs[name].nil? ? default : knobs[name]
      [name, value.is_a?(Numeric) ? value.to_f.constant.named(name.to_s) : value]
    }
    k = k.merge(s[:prepare].call) if s[:prepare]
    out = synth(midi, voices: voices || s[:voices]) { |v| s[:build].call(v, k) * s[:level] }
    out = out.hp1(s[:dc_block]) if s[:dc_block]
    s[:chorus] ? out.chorus(s[:chorus]) : out
  end

  # The description of +patch+ (the preset's), or of the script.
  def self.library_voices_description(patch)
    s = LIBRARY_VOICES.fetch(patch)
    "#{s[:about]} (#{s[:approach]}; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)"
  end

  if main_script?(__FILE__)
    knob_names = LIBRARY_VOICES.values.flat_map { |s| s[:knobs].keys }.uniq
    synth_script(
      description: ->(p) { library_voices_description(p.patch) },
      patch: [:fm_ep, Symbol, '-p', 'Patch to play', LIBRARY_VOICES.keys],
      voices: [nil, Integer, 'Voices (default: the patch\'s)', 1..16],
      **knob_names.to_h { |n|
        users = LIBRARY_VOICES.select { |_, s| s[:knobs].key?(n) }
        description = users.values.first[:knobs][n][2]
        lo = users.values.map { |s| s[:knobs][n][1].begin }.min
        hi = users.values.map { |s| s[:knobs][n][1].end }.max
        [n, [nil, Float, "#{description} (#{users.map { |name, s| "#{name} #{s[:knobs][n][0]}" }.join(', ')})", lo..hi]]
      },
    ) { |midi, p|
      s = LIBRARY_VOICES.fetch(p.patch)
      bad = knob_names.reject { |n| p[n].nil? || s[:knobs].key?(n) }
      raise ScriptRunner::InputError, "#{p.patch} has no #{bad.map { |n| "--#{n.to_s.tr('_', '-')}" }.join(', ')} (its knobs: #{s[:knobs].keys.join(', ')})" unless bad.empty?
      library_voice(midi, p.patch, voices: p.voices, **s[:knobs].keys.to_h { |n| [n, p[n]] })
    }
  end
end
