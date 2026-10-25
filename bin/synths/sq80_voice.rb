#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# An SQ-80-flavored playable synth built from the library's general pieces.
# The voice lives in the library (MB::Sound.sq80, SQ80::Voice; console
# `help :sq80`); this script plays it and its patches (-p, `sq80_patches`
# in bin/sound.rb lists them: classic, flutter_pad, chop, vox_lead,
# prime_bass, glass).  Options left out take the patch's values.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Three oscillators per voice (Ensoniq SQ-80 style, all original tables):
# OSC1 a "FORMT"-like wave whose formant stays put across 8-semitone key
# zones (Wavetable::KeyMap), OSC2 a SYNTH 3-style equal-harmonic table
# (harmonics 1, 2, 3, 5, 7, 11, 13, 17, 19, 23), OSC3 a PRIME-style table
# an octave down, blipped by a CYC envelope.  They feed the 4-pole lowpass
# (lp4) with its drive on the resonance feedback (soft clip, default) or the
# input, then a four-segment SQ-80 envelope (ENV4).
#
# Modulation (Notes#mod_scale / #mod_sum, Notes#lfo, Notes#sq80_env):
# - LFO1: delayed triangle vibrato; the mod wheel and aftertouch deepen it.
# - ENV2 (filter): L1-L3/T1-T4 with velocity on levels and attack time,
#   and higher keys shortening the decays.
# - Aftertouch (poly or channel) opens the filter.
# Oddities (try them):
# - Flutter: a sample-and-hold LFO per voice whose RATE and depth follow
#   that key's poly pressure, so each finger flutters the filter at its own
#   speed (--flutter, octaves; 0 for off).
# - Chop: a looping envelope (two 32nd-note segments, repeating while the
#   key is held) chopping the filter in time with the tempo, restarting
#   with each note, so chords stagger into polyrhythms (--chop, octaves).
#
# MIDI: CC 1 vibrato depth, CC 71 resonance, CC 74 brightness, CC 72/73/75
# envelope times (GM2), poly or channel pressure as above.
#
# Examples:
#     $0                                              # live MIDI (a keyboard with poly pressure shines)
#     $0 spec/test_data/c_major.mid sq80.flac
#     $0 spec/test_data/poly_chord.mid --flutter 2 chord.flac
#     $0 --drive-mode input --drive 3 spec/test_data/c_major.mid driven.flac
#     $0 --second-release --chop 0 spec/test_data/c_major.mid tail.flac
#     $0 -p flutter_pad spec/test_data/poly_chord.mid pad.flac
#     $0 -p prime_bass --cutoff 300 spec/test_data/c_major.mid bass.flac
#
# In bin/sound.rb (no load needed; sq80_voice(...) is the same after
# `load 'bin/synths/sq80_voice.rb'`):
#     play sq80                                       # live keyboard
#     play sq80(:flutter_pad)
#     bpm 100; bg :sq, sq80(seq(C4, E4, G4, B4).n8.loop, chop: 2)
#     bg :sq, sq80((seq(C3).n1 & seq(G3).n1 & seq(E4).n1).loop, flutter: 0, second_release: true)
#     bg :sq, sq80(seq(C4, E4, G4, B4).n8.loop, :chop, cutoff: 400)
#     preset :sq80_glass, midi: midi                  # the patches as graph documents
#
# Building blocks on their own (any voice v, e.g. midi.synth { |v| ... }):
#     v.sq80_env(l1: 63, l2: 30, l3: 45, t1: 20, t2: 24, t3: 30, t4: 32, second_release: true)
#     v.env([[1, 0.01], [-0.5, 0.2], [0.3, 0.4], [0, 0.5]], release_at: 3)     # any segments, bipolar
#     v.env([[1, 1.n32, 30], [0, 1.n32, -20], [0, 0.1]], release_at: 2, loop: 0) # a rhythmic loop
#     v.lfo(5, shape: :noise, delay: 0.5, wheel: 1)                              # S&H, fading in
#     v.lfo(v.mod_scale(2, :poly_pressure => 3.oct), shape: :tri)               # pressure sets the rate
#     v.mod_scale(800, env => 3.oct, :key => 0.5, :velocity => 1.oct)           # a filter mod matrix
#     v.hz.transpose(v.mod_sum(lfo => 0.3, :bend => 2))                          # pitch slots in semitones

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The SQ-80-style synth graph for MIDI +midi+ (a Notes, Clip, filename,
  # or other source; see MidiMethods#synth): MB::Sound.sq80 (kept for
  # scripts and snippets that load this file).
  def self.sq80_voice(midi, patch = nil, **settings)
    sq80(midi, patch, **settings)
  end

  # Script parameters that save as graph document params when given (each
  # a Constant named after it; zero chop or flutter is structural, "off").
  SQ80_VOICE_PARAMS = [:cutoff, :reso, :chop, :flutter].freeze

  # The script's graph: SQ-80 +patch+ on +midi+ with +settings+ (only those
  # given; the rest are the patch's), numeric SQ80_VOICE_PARAMS as named
  # Constants so --save makes them params (the same samples as numbers).
  def self.sq80_voice_patch(midi, patch = :classic, **settings)
    settings = settings.to_h { |k, v|
      named = SQ80_VOICE_PARAMS.include?(k) && v.is_a?(Numeric) && v != 0
      [k, named ? v.to_f.constant.named(k.to_s) : v]
    }
    sq80(midi, patch, **settings)
  end

  # What each patch is, for preset descriptions (--save writes it into the
  # document): +what+ is the patch (a Symbol) or a phrase.
  def self.sq80_voice_description(what)
    what = "SQ-80 voice :#{what}: #{SQ80.patch(what).description}" if what.is_a?(Symbol)
    "#{what} (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)"
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { sq80_voice_description(p.patch) },
      patch: [:classic, Symbol, '-p', 'Patch to play (sq80_patches lists them)', SQ80.patch_names],
      voices: [nil, Integer, 'Voices (default: the patch\'s, 8 for classic)', 1..16],
      cutoff: [nil, Float, 'Filter cutoff in Hz before modulation (classic 500)', 20.0..10000.0],
      reso: [nil, Float, 'Resonance 0..1, CC 71 moves it (classic 0.4)', 0.0..1.0],
      drive_mode: [nil, Symbol, 'lp4 drive: feedback (soft-clipped resonance) or input (classic feedback)', [:feedback, :input]],
      drive: [nil, Float, 'lp4 drive amount (classic 1.5)', 0.1..10.0],
      chop: [nil, Float, 'Looping chop envelope depth in octaves, 0: off (classic 1.5)', 0.0..6.0],
      flutter: [nil, Float, 'Poly pressure flutter depth in octaves, 0: off (classic 1.0)', 0.0..4.0],
      second_release: [false, '-r', 'SQ-80 second release (a pseudo-reverb tail) on the VCA (on in some patches already)'],
    ) { |midi, p|
      settings = {
        voices: p.voices, cutoff: p.cutoff, reso: p.reso, drive_mode: p.drive_mode, drive: p.drive,
        chop: p.chop, flutter: p.flutter, second_release: p.second_release || nil,
      }.compact
      sq80_voice_patch(midi, p.patch, **settings)
    }
  end
end
