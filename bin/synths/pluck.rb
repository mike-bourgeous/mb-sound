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
#     $0 -H 10500 -a 1 spec/test_data/c_major.mid            # the old voice's bright noise, first period faded in
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
  # The longest string period (seconds) pluck_voice's delay line holds:
  # 1/12.5 Hz, so a low E1 (41.2 Hz) bent down an octave with a 12-semitone
  # bend range still bends (the line clamps below 12.5 Hz).
  MAX_PLUCK_PERIOD = 0.08 unless const_defined?(:MAX_PLUCK_PERIOD)

  # A Karplus-Strong voice for Notes +v+ (see the script description):
  # +sustain+ is the time in seconds for the string to fall 60 dB (at any
  # pitch: the loop gain per period follows the note), +damping+ the loop
  # lowpass cutoff as a multiple of the pitch (0 for none), +pick+ the
  # burst's length in periods of the note (1 is classic Karplus-Strong),
  # +brightness+ the burst's lowpass at full velocity as a multiple of the
  # pitch, +stretch+ a softclip drive in the loop (0 for none).
  # +brightness_hz+, if positive, replaces +brightness+ with a fixed cutoff
  # at full velocity (from 1500 Hz at velocity 0, like the pre-2026-10-09
  # voice's 1500 + 9000 x velocity: 10500).  +attack+ fades the string in
  # over that many periods from when it starts sounding (one period after
  # the note-on), so its first, noisiest periods are softer (0 for none);
  # +attack_shape+ :linear or :s (smoothstep: gentler at the start).
  # +glide+ (seconds, 0 for none) slides legato notes (a mono synth,
  # voices: 1) to the new pitch without plucking again: the string's delay
  # follows the glide, so the ringing string bends.
  def self.pluck_voice(v, sustain: 3.0, damping: 6.0, pick: 1.0, brightness: 12.0, stretch: 0.0, release: 0.08,
                       brightness_hz: 0.0, attack: 0.0, attack_shape: :linear, glide: 0.0)
    # The string's pitch (bend included), gliding between legato notes
    freq = glide > 0 ? v.hz.glide(glide, legato: true).freq : v.freq
    period = glide > 0 ? 1 / freq : v.period

    # The excitation: +pick+ periods of noise written into the string's
    # delay line (classic Karplus-Strong fills the line with one period),
    # through a lowpass that harder notes open (up to +brightness+ times the
    # pitch)
    burst_env = if glide > 0
                  # Gated (the burst, then 0 while held) so legato notes don't pluck again
                  v.env([[1, 0, 0], [1, period * pick, 0], [0, 0, 0], [0, 0, 0]], release_at: 3, gm: false, sensitivity: 0.3..1.0).legato
                else
                  v.env(0, 0, 1, 0, gate: false, gm: false, hold: period * pick, sensitivity: 0.3..1.0)
                end
    burst_cutoff = brightness_hz > 0 ? 1500 + v.velocity * (brightness_hz - 1500) : freq * (1 + v.velocity * brightness)
    burst = noise.filter(:lowpass, cutoff: burst_cutoff, quality: 0.6) * burst_env

    # Loop gain per period for a 60 dB fall in +sustain+ seconds at the note's pitch
    gain = 10.constant ** (-3.0 / sustain / freq)

    # The mod wheel darkens the string: the loop lowpass from +damping+ down to 2x the pitch
    if damping > 0
      wheel = v.cc(1, range: 0.0..1.0, name: 'Damping', description: 'Darkens the string (loop lowpass)')
      cutoff = freq * (damping - (damping - 2) * wheel)
    end

    # The string is the loop's output after the delay, average, and lowpass:
    # the burst only enters the delay line, so it is heard once it has been
    # through the string's damping (one period later), never raw
    string = burst.feedback { |fb, input|
      d = (fb + input).delay(period, smoothing: false, max_delay: MAX_PLUCK_PERIOD)
      s = (d + d.delay(1.samples)) * (gain * 0.5)
      s = s.filter(:lowpass, cutoff: cutoff, quality: 0.5**0.5) if damping > 0
      s = (s * (1 + stretch)).softclip(0.3, 1) * (1.0 / (1 + stretch)) if stretch > 0
      s
    }

    # Makeup gain to the level of the other synth scripts (a plucked string
    # spends most of its time decaying)
    string * pluck_output_env(v, release: release, attack: attack, attack_shape: attack_shape, delay: 1, period: period) * 4
  end

  # The output envelope of pluck_voice: silent for +delay+ periods (until
  # the string sounds), then a fade-in over +attack+ periods (+attack_shape+
  # :linear or :s), full level while held, and a +release+ in seconds.
  # Without an attack, the plain gate (an amp_env with no attack).
  def self.pluck_output_env(v, release:, attack: 0, attack_shape: :linear, delay: 1, period: v.period)
    return v.amp_env(0, 0, 1, release) if attack <= 0

    v.amp_env([[0, period * delay, 0, :exp], [1, period * attack, 0, attack_shape == :s ? :s : :exp], [0, release]])
  end

  if main_script?(__FILE__)
    synth_script(
      sustain: [3.0, Float, '-s', 'Seconds for the string to fall 60 dB', 0.05..60.0],
      damping: [6.0, Float, '-d', 'Loop lowpass cutoff as a multiple of the pitch (0 for none; the mod wheel lowers it to 2x)', 0.0..64.0],
      pick: [1.0, Float, '-k', 'Length of the noise burst in periods of the note (1 is classic Karplus-Strong)', 0.25..8.0],
      brightness: [12.0, Float, '-B', 'Noise lowpass at full velocity as a multiple of the pitch (softer notes are darker)', 0.5..64.0],
      stretch: [0.0, Float, '-t', 'Softclip drive inside the loop (0 for none; buzzy, sitar-like)', 0.0..20.0],
      brightness_hz: [0.0, Float, '-H', 'Noise lowpass at full velocity in Hz instead of --brightness (0: off; the old voice used 10500)', 0.0..20000.0],
      attack: [0.0, Float, '-a', 'Fade the string in over this many periods (softens the pluck noise; 0 for none)', 0.0..64.0],
      attack_shape: [:linear, '-A', 'Attack fade shape', [:linear, :s]],
      glide: [0.0, Float, '-G', 'Glide time in seconds between legato notes (with --voices 1; 0 for none)', 0.0..5.0],
      release: [0.08, Float, '-r', 'Release time in seconds after note-off (the string is muted)', 0.0..5.0],
      voices: [6, Integer, '-v', 'Number of voices', 1..32],
    ) { |midi, p|
      midi.synth(voices: p.voices) { |v|
        pluck_voice(v, sustain: p.sustain, damping: p.damping, pick: p.pick, brightness: p.brightness, stretch: p.stretch, release: p.release,
          brightness_hz: p.brightness_hz, attack: p.attack, attack_shape: p.attack_shape, glide: p.glide)
      }
    }
  end
end
