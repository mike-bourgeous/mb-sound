#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A Karplus-Strong plucked string synth: each note writes one period of
# noise (classic Karplus-Strong; --pick changes the length) into a feedback
# loop whose delay is one period of the note (GraphNode#feedback), with the
# classic two-sample average (and an optional lowpass) damping the string
# in the loop.  The string is the loop's output, so the burst is only heard
# once it has gone around the string (no raw noise on the output).  The
# loop runs one sample at a time and absorbs its own latency (the average's
# half sample, the lowpass's group delay), so notes are in tune (within a
# few hundredths of a cent without --damping; within about 2 cents with
# --damping 4).
# (C)2026 Mike Bourgeous
#
# Usage: $0 [options] [midi_file [output_file]]
#
# Plays live MIDI (or a MIDI file) through 6 voices.  Velocity sets the
# pluck's level and brightness (a lowpass on the noise, up to --brightness
# times the pitch).  CC 1 (the mod wheel) darkens the string (the loop's
# lowpass, from --damping down to 2x the pitch; the loop's sustain keeps the
# ring time, so only the tone changes).  Run with --help for all options.
#
# Examples:
#     $0 spec/test_data/c_major.mid                          # nylon-ish strings
#     $0 --sustain 8 --damping 0 spec/test_data/c_major.mid  # bright, ringing (no loop lowpass)
#     $0 --sustain 0.6 --brightness 3 spec/test_data/c_major.mid   # muted, plucky
#     $0 --pick 4 spec/test_data/c_major.mid                 # a longer, scratchier pick
#     $0 --stretch 2 spec/test_data/c_major.mid               # a softclip in the loop: buzzy, sitar-like
#
# Karplus-Strong in the console (bin/sound.rb): one period of noise goes
# into the delay line, and the loop's output (after the delay and the
# average) is the string, so the noise is heard only through the string
# (adding the burst to the output instead plays it raw, far above the ring;
# and_then keeps the input going after the burst so the loop rings on):
#     exc = (noise.at(0.5) * adsr(0, 0, 1, 0, hold: 220.hz.period)).and_then(0.constant)
#     play exc.feedback { |fb, input| d = (fb + input).delay(220.hz.period, smoothing: false); (d + d.delay(1.samples)) * 0.498 }
#     # The same string, out of tune without latency compensation (about 4 cents flat at 220 Hz)
#     play exc.feedback(compensate: false) { |fb, input| d = (fb + input).delay(220.hz.period, smoothing: false); (d + d.delay(1.samples)) * 0.498 }
#     # A loop lowpass at 2x the pitch: in tune at the played pitch (the
#     # default), about 10 cents flat with compensate: :dc
#     exc = (noise.at(0.5) * adsr(0, 0, 1, 0, hold: 440.hz.period)).and_then(0.constant)
#     play exc.feedback { |fb, input| d = (fb + input).delay(440.hz.period, smoothing: false); ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 880, quality: 0.5**0.5) }
#     play exc.feedback(compensate: :dc) { |fb, input| d = (fb + input).delay(440.hz.period, smoothing: false); ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 880, quality: 0.5**0.5) }
#     # sustain (the default) keeps the ring time while the lowpass darkens it: without it the
#     # fundamental's T60 falls from 4.7 s to 0.47 s (sweep the cutoff with a slow LFO to compare)
#     play exc.feedback(sustain: false) { |fb, input| d = (fb + input).delay(440.hz.period, smoothing: false); ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 0.3.hz.lfo.at(440..3520), quality: 0.5**0.5) }
#     play exc.feedback { |fb, input| d = (fb + input).delay(440.hz.period, smoothing: false); ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 0.3.hz.lfo.at(440..3520), quality: 0.5**0.5) }
#     # A delay time that moves: the string bends (try a slow LFO)
#     exc = (noise.at(0.5) * adsr(0, 0, 1, 0, hold: 220.hz.period)).and_then(0.constant)
#     play exc.feedback { |fb, input| d = (fb + input).delay((1 / (220.hz.freq * 0.3.hz.lfo.at(1..1.06))), smoothing: false); (d + d.delay(1.samples)) * 0.498 }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # A Karplus-Strong voice for Notes +v+ (see the script description):
  # +sustain+ is the time in seconds for the string to fall 60 dB (at any
  # pitch: the loop gain per period follows the note), +damping+ the loop
  # lowpass cutoff as a multiple of the pitch (0 for none), +pick+ the
  # burst's length in periods of the note (1 is classic Karplus-Strong),
  # +brightness+ the burst's lowpass at full velocity as a multiple of the
  # pitch, +stretch+ a softclip drive in the loop (0 for none).
  def self.pluck_voice(v, sustain: 3.0, damping: 6.0, pick: 1.0, brightness: 12.0, stretch: 0.0, release: 0.08)
    # The excitation: +pick+ periods of noise written into the string's
    # delay line (classic Karplus-Strong fills the line with one period),
    # through a lowpass that harder notes open (up to +brightness+ times the
    # pitch)
    burst_env = v.env(0, 0, 1, 0, gate: false, gm: false, hold: v.period * pick, sensitivity: 0.3..1.0)
    burst = noise.filter(:lowpass, cutoff: v.freq * (1 + v.velocity * brightness), quality: 0.6) * burst_env

    # Loop gain per period for a 60 dB fall in +sustain+ seconds at the note's pitch
    gain = 10.constant ** (-3.0 / sustain / v.freq)

    # The mod wheel darkens the string: the loop lowpass from +damping+ down to 2x the pitch
    if damping > 0
      wheel = v.cc(1, range: 0.0..1.0, name: 'Damping', description: 'Darkens the string (loop lowpass)')
      cutoff = v.freq * (damping - (damping - 2) * wheel)
    end

    # The string is the loop's output after the delay, average, and lowpass:
    # the burst only enters the delay line, so it is heard once it has been
    # through the string's damping (one period later), never raw
    string = burst.feedback { |fb, input|
      d = (fb + input).delay(v.period, smoothing: false, max_delay: 0.05)
      s = (d + d.delay(1.samples)) * (gain * 0.5)
      s = s.filter(:lowpass, cutoff: cutoff, quality: 0.5**0.5) if damping > 0
      s = (s * (1 + stretch)).softclip(0.3, 1) * (1.0 / (1 + stretch)) if stretch > 0
      s
    }

    # Makeup gain to the level of the other synth scripts (a plucked string
    # spends most of its time decaying)
    string * v.amp_env(0, 0, 1, release) * 4
  end

  if main_script?(__FILE__)
    synth_script(
      sustain: [3.0, Float, '-s', 'Seconds for the string to fall 60 dB', 0.05..60.0],
      damping: [6.0, Float, '-d', 'Loop lowpass cutoff as a multiple of the pitch (0 for none; the mod wheel lowers it to 2x)', 0.0..64.0],
      pick: [1.0, Float, '-k', 'Length of the noise burst in periods of the note (1 is classic Karplus-Strong)', 0.25..8.0],
      brightness: [12.0, Float, '-B', 'Noise lowpass at full velocity as a multiple of the pitch (softer notes are darker)', 0.5..64.0],
      stretch: [0.0, Float, '-t', 'Softclip drive inside the loop (0 for none; buzzy, sitar-like)', 0.0..20.0],
      release: [0.08, Float, '-r', 'Release time in seconds after note-off (the string is muted)', 0.0..5.0],
      voices: [6, Integer, '-v', 'Number of voices', 1..32],
    ) { |midi, p|
      midi.synth(voices: p.voices) { |v|
        pluck_voice(v, sustain: p.sustain, damping: p.damping, pick: p.pick, brightness: p.brightness, stretch: p.stretch, release: p.release)
      }
    }
  end
end
