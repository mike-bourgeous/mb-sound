#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A Karplus-Strong plucked string synth: each note starts a short noise
# burst into a feedback loop whose delay is one period of the note
# (GraphNode#feedback), with the classic two-sample average (and an
# optional lowpass) damping the string in the loop.  The loop runs one
# sample at a time and absorbs its own latency (the average's half sample,
# the lowpass's group delay), so notes are in tune (within a few hundredths
# of a cent without --damping; within about 2 cents with --damping 4).
# (C)2026 Mike Bourgeous
#
# Usage: $0 [options] [midi_file [output_file]]
#
# Plays live MIDI (or a MIDI file) through 6 voices.  CC 1 (the mod wheel)
# darkens the string (the loop's lowpass, from --damping down to 2x the
# pitch).  Run with --help for all options.
#
# Examples:
#     $0 spec/test_data/c_major.mid                          # nylon-ish strings
#     $0 --sustain 8 --damping 0 spec/test_data/c_major.mid  # bright, ringing (no loop lowpass)
#     $0 --sustain 0.6 --pick 0.004 spec/test_data/c_major.mid   # muted, plucky
#     $0 --stretch 2 spec/test_data/c_major.mid               # a softclip in the loop: buzzy, sitar-like
#
# Karplus-Strong in the console (bin/sound.rb):
#     exc = noise.at(0.5) * adsr(0, 0.003, 0, 0.003, hold: false)
#     play exc.feedback { |fb, input| d = fb.delay(220.hz.period, smoothing: false); input + (d + d.delay(1.samples)) * 0.498 }
#     # The same string, out of tune without latency compensation (about 4 cents flat at 220 Hz)
#     play exc.feedback(compensate: false) { |fb, input| d = fb.delay(220.hz.period, smoothing: false); input + (d + d.delay(1.samples)) * 0.498 }
#     # A loop lowpass at 2x the pitch: in tune at the played pitch (the default), about 13 cents flat with compensate: :dc
#     play exc.feedback { |fb, input| d = fb.delay(440.hz.period, smoothing: false); input + ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 880, quality: 0.5**0.5) }
#     play exc.feedback(compensate: :dc) { |fb, input| d = fb.delay(440.hz.period, smoothing: false); input + ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 880, quality: 0.5**0.5) }
#     # A delay time that moves: the string bends (try a slow LFO)
#     play exc.feedback { |fb, input| d = fb.delay((1 / (220.hz.freq * 0.3.hz.lfo.at(1..1.06))), smoothing: false); input + (d + d.delay(1.samples)) * 0.498 }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # A Karplus-Strong voice for Notes +v+ (see the script description):
  # +sustain+ is the time in seconds for the string to fall 60 dB (at any
  # pitch: the loop gain per period follows the note), +damping+ the loop
  # lowpass cutoff as a multiple of the pitch (0 for none), +pick+ the
  # burst's length in seconds, +stretch+ a softclip drive in the loop (0 for
  # none).
  def self.pluck_voice(v, sustain: 3.0, damping: 6.0, pick: 0.008, stretch: 0.0, release: 0.08)
    # The burst: noise through a velocity-bright lowpass, decaying over the pick time
    burst_env = v.env(0, pick, 0, pick, sensitivity: 0.3..1.0)
    burst = noise.filter(:lowpass, cutoff: v.velocity * 9000 + 1500, quality: 0.6) * burst_env

    # Loop gain per period for a 60 dB fall in +sustain+ seconds at the note's pitch
    gain = 10.constant ** (-3.0 / sustain / v.freq)

    # The mod wheel darkens the string: the loop lowpass from +damping+ down to 2x the pitch
    if damping > 0
      wheel = v.cc(1, range: 0.0..1.0, name: 'Damping', description: 'Darkens the string (loop lowpass)')
      cutoff = v.freq * (damping - (damping - 2) * wheel)
    end

    string = burst.feedback { |fb, input|
      d = fb.delay(v.period, smoothing: false, max_delay: 0.05)
      s = (d + d.delay(1.samples)) * (gain * 0.5)
      s = s.filter(:lowpass, cutoff: cutoff, quality: 0.5**0.5) if damping > 0
      s = (s * (1 + stretch)).softclip(0.3, 1) * (1.0 / (1 + stretch)) if stretch > 0
      input + s
    }

    # Makeup gain to the level of the other synth scripts (a plucked string
    # spends most of its time decaying)
    string * v.amp_env(0, 0, 1, release) * 4
  end

  if main_script?(__FILE__)
    synth_script(
      sustain: [3.0, Float, '-s', 'Seconds for the string to fall 60 dB', 0.05..60.0],
      damping: [6.0, Float, '-d', 'Loop lowpass cutoff as a multiple of the pitch (0 for none; the mod wheel lowers it to 2x)', 0.0..64.0],
      pick: [0.008, Float, '-k', 'Length of the noise burst in seconds', 0.0005..0.1],
      stretch: [0.0, Float, '-t', 'Softclip drive inside the loop (0 for none; buzzy, sitar-like)', 0.0..20.0],
      release: [0.08, Float, '-r', 'Release time in seconds after note-off (the string is muted)', 0.0..5.0],
      voices: [6, Integer, '-v', 'Number of voices', 1..32],
    ) { |midi, p|
      midi.synth(voices: p.voices) { |v|
        pluck_voice(v, sustain: p.sustain, damping: p.damping, pick: p.pick, stretch: p.stretch, release: p.release)
      }
    }
  end
end
