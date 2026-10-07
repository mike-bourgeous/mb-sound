#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# An SQ-80-flavored playable synth built from the library's general pieces.
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
#
# In bin/sound.rb:
#     load 'bin/synths/sq80_voice.rb'
#     play sq80_voice(midi)                           # live keyboard
#     bpm 100; bg :sq, sq80_voice(seq(C4, E4, G4, B4).n8.loop, chop: 2)
#     bg :sq, sq80_voice((seq(C3).n1 & seq(G3).n1 & seq(E4).n1).loop, flutter: 0, second_release: true)
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
  # Original wave tables in the spirit of the SQ-80's waves (built from the
  # manual's descriptions; nothing from its ROM).
  module SQ80Waves
    module_function

    # Equal-level harmonics (the SQ-80's SYNTH and PRIME waves).
    def equal(harmonics)
      amps = Array.new(harmonics.max, 0.0)
      harmonics.each { |h| amps[h - 1] = 1.0 }
      Wavetable::Library.peak_normalized(amps)
    end

    def synth3
      @synth3 ||= equal([1, 2, 3, 5, 7, 11, 13, 17, 19, 23])
    end

    def prime
      @prime ||= equal([1, 3, 5, 7, 11])
    end

    # A formant wave per 8-semitone zone (like the SQ-80's FORMT and VOICE
    # multisamples): a 1/h spectrum lifted around fixed formants at 750 Hz
    # and 1.4 kHz for each zone's center note, so the vowel stays put as the
    # pitch moves.
    def formant
      @formant ||= Wavetable::KeyMap.zones(
        Array.new(11) { |i|
          f0 = 440.0 * 2 ** ((24 + 8 * i + 4 - 69) / 12.0)
          count = [(18000 / f0).floor, 256].min
          amps = Array.new(count) { |k|
            f = f0 * (k + 1)
            peak = 1.0 * Math.exp(-((f - 750) / 220.0)**2) + 0.6 * Math.exp(-((f - 1400) / 300.0)**2)
            (0.25 + 3 * peak) / (k + 1)
          }
          Wavetable::Library.peak_normalized(amps)
        },
        from: 24, size: 8
      )
    end
  end

  # The SQ-80-style synth graph for MIDI +midi+ (a Notes, Clip, filename,
  # or other source; see MidiMethods#synth).  Options as in the script's
  # parameters.
  def self.sq80_voice(midi, voices: 8, cutoff: 500, reso: 0.4, drive_mode: :feedback, drive: 1.5, chop: 1.5, flutter: 1.0, second_release: false)
    formant = SQ80Waves.formant
    synth3 = SQ80Waves.synth3
    prime = SQ80Waves.prime

    synth(midi, voices: voices) { |v|
      # LFO1: delayed vibrato (semitones), deeper with the wheel and aftertouch
      vibrato = v.lfo(5.2, shape: :tri, depth: 0.06, delay: 0.4, wheel: 0.35, pressure: 0.2)

      # OSC1-3 (OSC2 a few cents up, OSC3 an octave down)
      osc1 = v.hz.transpose(vibrato).wavetable(formant)
      osc2 = v.hz.transpose(v.mod_sum(0.06, vibrato => 1)).wavetable(synth3)
      osc3 = v.hz.transpose(-12).wavetable(prime)

      # GM2 envelope time knobs (CC 72/73/75) act on ENV4 only (cheaper)

      # ENV1 blips OSC3 (CYC: every stage runs, even for a short key-up)
      env1 = v.sq80_env(l1: 63, l2: 18, l3: 0, t1: 0, t2: 14, t3: 20, t4: 16, lv: 30, cycle: true, gm: false)

      # ENV2: the filter; velocity on levels and attack, higher keys decay faster
      env2 = v.sq80_env(l1: 63, l2: 36, l3: 24, t1: 4, t2: 28, t3: 38, t4: 30, lv: 24, t1v: 30, tk: 24, gm: false)

      mods = { env2 => 3.oct, :key => 0.5, :velocity => 0.5.oct, :aftertouch => 1.5.oct }

      # Oddity 1: each finger's pressure sets its own S&H flutter rate and depth
      if flutter != 0
        flutter_lfo = v.lfo(v.mod_scale(2.5, :poly_pressure => 2.5.oct), shape: :noise)
        mods[flutter_lfo] = v.poly_pressure * flutter.to_f
      end

      # Oddity 2: a looping envelope chops the filter in 16ths while held
      if chop != 0
        chopper = v.env([[1, 1.n32, 24], [0, 1.n32, -12], [0, 0.15]], release_at: 2, loop: 0, curve: :linear, sensitivity: 0, gm: false)
        mods[chopper] = chop.to_f.oct
      end

      cut = v.mod_scale(cutoff, mods) * v.brightness
      drive_opts = drive_mode.to_sym == :input ? { drive: drive, drive_mode: :input } : { drive: drive, drive_mode: :feedback, clip: :soft }

      # ENV4: the VCA, exponential velocity on its levels (LV "X")
      env4 = v.sq80_env(l1: 63, l2: 54, l3: 46, t1: 2, t2: 30, t3: 42, t4: 32, lv: 36, lv_curve: :exp, second_release: second_release)

      ((osc1 * 0.45 + osc2 * 0.35 + osc3 * env1 * 0.4)
        .lp4(cut.clip(20, 18000), resonance: v.reso(reso), **drive_opts) * env4)
    } * 1.6
  end

  if main_script?(__FILE__)
    synth_script(
      voices: [8, Integer, 'Voices', 1..16],
      cutoff: [500, Float, 'Filter cutoff in Hz before modulation', 20..10000],
      reso: [0.4, Float, 'Resonance 0..1 (CC 71 moves it)', 0.0..1.0],
      drive_mode: [:feedback, Symbol, 'lp4 drive: feedback (soft-clipped resonance) or input', [:feedback, :input]],
      drive: [1.5, Float, 'lp4 drive amount', 0.1..10.0],
      chop: [1.5, Float, 'Looping chop envelope depth in octaves (0: off)', 0.0..6.0],
      flutter: [1.0, Float, 'Poly pressure flutter depth in octaves (0: off)', 0.0..4.0],
      second_release: [false, '-r', 'SQ-80 second release (a pseudo-reverb tail) on the VCA'],
    ) { |midi, p|
      sq80_voice(
        midi, voices: p.voices, cutoff: p.cutoff, reso: p.reso, drive_mode: p.drive_mode, drive: p.drive,
        chop: p.chop, flutter: p.flutter, second_release: p.second_release
      )
    }
  end
end
