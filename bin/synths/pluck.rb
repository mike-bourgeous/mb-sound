#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A Karplus-Strong plucked string synth: each note excites a feedback loop
# whose delay is one period of the note (GraphNode#feedback), with the
# classic two-sample average (and an optional lowpass) damping the string
# in the loop.  The loop runs one sample at a time and absorbs its own
# latency (the average's half sample, the lowpass's group delay), so notes
# are in tune (within a few hundredths of a cent without --damping; within
# about 2 cents with --damping 4).
#
# Two excitations, crossfaded by each note's pitch over an octave around
# --crossover (1 kHz; user's picks by ear, 2026-10-10):
# - bright (low notes): an 8 ms noise burst heard raw at the start and
#   going around the string, faded in over one period (the
#   pre-2026-10-09 voice; --click lowers the raw part against the ring);
# - clean (high notes): one period of noise (classic Karplus-Strong;
#   --pick changes the length) written into the delay line only, so it is
#   heard once it has gone around the string, faded in over two periods
#   after that first one.
# --bright or --clean plays one of them at every pitch.
# (C)2026 Mike Bourgeous
#
# Usage: $0 [options] [midi_file [output_file]]
#
# Plays live MIDI (or a MIDI file) through 6 voices.  Velocity sets the
# pluck's level and brightness (a lowpass on the noise; up to --brightness
# times the pitch on the clean voice).  CC 1 (the mod wheel) darkens the
# string (the loop's lowpass, from --damping down to 2x the pitch; the
# loop's sustain keeps the ring time, so only the tone changes).  With
# --hammer (one voice), legato notes are hammer-ons (going up) and
# pull-offs (going down, also when the top note is released while a lower
# one is held): the pitch jumps and the still ringing string gets a small
# new pick (--hammer-level, --pull-level).  Run with --help for all
# options.
#
# Examples:
#     $0 spec/test_data/c_major.mid                          # nylon-ish strings
#     $0 --sustain 8 --damping 0 spec/test_data/c_major.mid  # bright, ringing (no loop lowpass)
#     $0 --sustain 0.6 --brightness 3 spec/test_data/c_major.mid   # muted, plucky
#     $0 --bright -C 0.5 spec/test_data/c_major.mid          # the bright voice everywhere, half the click
#     $0 --clean --pick 4 spec/test_data/c_major.mid         # classic KS everywhere, a longer, scratchier pick
#     $0 --stretch 2 spec/test_data/c_major.mid               # a softclip in the loop: buzzy, sitar-like
#     $0 --hammer                                            # live: play legato for hammer-ons and pull-offs
#     $0 -v 1 -G 0.1                                         # live: legato notes slide instead
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

  # Defaults of pluck_voice's pitch crossfade (see pluck_voice): the
  # bright voice below, the clean voice above, crossfaded (smoothstep in
  # Hz) over an octave centered on PLUCK_CROSSOVER Hz.
  PLUCK_CROSSOVER = 1000.0 unless const_defined?(:PLUCK_CROSSOVER)

  # A Karplus-Strong voice for Notes +v+ (see the script description).
  #
  # Two excitations (user's picks by ear, 2026-10-10), crossfaded per note
  # by its pitch (+voice:+ :auto, the default) over an octave around
  # +crossover+ Hz, or one of them at every pitch (+voice:+ :bright or
  # :clean):
  # - bright (low notes; the pre-2026-10-09 voice): an 8 ms (+bright_pick+
  #   seconds) noise burst lowpassed at 1500 + 9000 x velocity Hz, heard
  #   raw on the output (the bright, scratchy start) and going around the
  #   string; the output fades in over one period from the note-on.
  #   +click+ scales the raw part (the start's brightness) against the ring
  #   (1 = the old voice; 0.5 is 6 dB less click, same ring).
  # - clean (high notes; classic Karplus-Strong): +pick+ periods of noise,
  #   lowpassed at the pitch x (1 + velocity x +brightness+) (or from 1500 Hz
  #   up to +brightness_hz+ if positive), written into the delay line only,
  #   so it is heard once it has been through the string; the output is
  #   silent for that first period, then fades in over two.
  # The bright voice's level follows the pitch (PLUCK_BRIGHT_GAIN) so its
  # ring matches the clean voice's and the keyboard stays even.
  #
  # +sustain+ is the time in seconds for the string to fall 60 dB (at any
  # pitch: the loop gain per period follows the note), +damping+ the loop
  # lowpass cutoff as a multiple of the pitch (0 for none), +stretch+ a
  # softclip drive in the loop (0 for none).  +attack+ (periods; nil: 1 for
  # the bright voice, 2 for the clean one, crossfaded) fades the string in
  # (0 for none); +attack_shape+ :linear or :s (smoothstep: gentler at the
  # start).
  #
  # Legato (a mono synth, voices: 1): +glide+ (seconds, 0 for none) slides
  # legato notes to the new pitch without plucking again: the string's
  # delay follows the glide, so the ringing string bends.  +hammer+ instead
  # makes legato notes hammer-ons and pull-offs: the pitch jumps at once
  # and the string, still ringing, gets a small new pick of +hammer_level+
  # (going up) or +pull_level+ (going down) times a full one.
  def self.pluck_voice(v, sustain: 3.0, damping: 6.0, pick: 1.0, brightness: 12.0, stretch: 0.0, release: 0.08,
                       brightness_hz: 0.0, attack: nil, attack_shape: :linear, glide: 0.0,
                       voice: :auto, crossover: PLUCK_CROSSOVER, click: 1.0, bright_pick: 0.008,
                       hammer: false, hammer_level: 0.25, pull_level: 0.12)
    raise ArgumentError, "Unknown pluck voice #{voice.inspect} (:auto, :bright, :clean)" unless [:auto, :bright, :clean].include?(voice)
    raise ArgumentError, 'Choose either a glide or hammer-ons' if hammer && glide > 0

    # The string's pitch (bend included), gliding between legato notes
    freq = glide > 0 ? v.hz.glide(glide, legato: true).freq : v.freq
    period = glide > 0 ? 1 / freq : v.period

    # How much of the clean voice (0 = bright, 1 = clean): a number, or a
    # node of the note's pitch for :auto
    mix = case voice
          when :bright then 0
          when :clean then 1
          else freq.aease(:smoothstep, in: (crossover / Math.sqrt(2))..(crossover * Math.sqrt(2)))
          end

    # Legato notes: hammer-ons and pull-offs (note-ons, and returns to a
    # held note) get a fraction of a pick (held from each pick), else every
    # note-on is a full pick
    # (both noise sources are made in this order whatever the voice, so each
    # draws the same seed in every mode)
    clean_noise = noise
    bright_noise = noise

    pick_trigger, level, fresh = hammer ? pluck_hammer_picks(v, hammer_level: hammer_level, pull_level: pull_level) : nil

    # The clean excitation: +pick+ periods of noise written into the
    # string's delay line (classic Karplus-Strong fills the line with one
    # period), through a lowpass that harder notes open
    if mix != 0
      clean_env = if glide > 0
                    # Gated (the burst, then 0 while held) so legato notes don't pluck again
                    v.env([[1, 0, 0], [1, period * pick, 0], [0, 0, 0], [0, 0, 0]], release_at: 3, gm: false, sensitivity: 0.3..1.0).legato
                  elsif hammer
                    v.env(0, 0, 1, 0, gate: false, gm: false, hold: period * pick, sensitivity: 0.3..1.0, trigger: pick_trigger)
                  else
                    v.env(0, 0, 1, 0, gate: false, gm: false, hold: period * pick, sensitivity: 0.3..1.0)
                  end
      clean_cutoff = brightness_hz > 0 ? 1500 + v.velocity * (brightness_hz - 1500) : freq * (1 + v.velocity * brightness)
      clean = clean_noise.filter(:lowpass, cutoff: clean_cutoff, quality: 0.6) * clean_env
      clean *= mix unless mix == 1
      clean *= level if level
    else
      clean = 0.constant
    end

    bright_raw = bright_string = nil

    # The bright excitation: a short burst on the output and around the
    # string, raised with the pitch's PLUCK_BRIGHT_GAIN to the clean ring
    if mix != 1
      bright_env = if hammer
                     v.env(0, bright_pick, 0, bright_pick, gate: false, hold: bright_pick, gm: false, sensitivity: 0.3..1.0, trigger: pick_trigger)
                   else
                     v.env(0, bright_pick, 0, bright_pick, gm: false, sensitivity: 0.3..1.0)
                   end
      bright_env = bright_env.legato if glide > 0
      bright = bright_noise.filter(:lowpass, cutoff: v.velocity * 9000 + 1500, quality: 0.6) * bright_env * pluck_bright_gain(freq)
      bright *= (1 - mix) unless mix == 0
      bright *= level if level
      # +click+ < 1: the rest of the burst goes into the string only (and
      # all of a hammer-on's or pull-off's: the string is not plucked)
      raw = fresh ? fresh * click : click
      bright_raw = raw == 1 ? bright : bright * raw
      bright_string = raw == 1 ? nil : bright * (1 - raw)
    end

    # Loop gain per period for a 60 dB fall in +sustain+ seconds at the note's pitch
    gain = 10.constant ** (-3.0 / sustain / freq)

    # The mod wheel darkens the string: the loop lowpass from +damping+ down to 2x the pitch
    if damping > 0
      wheel = v.cc(1, range: 0.0..1.0, name: 'Damping', description: 'Darkens the string (loop lowpass)')
      cutoff = freq * (damping - (damping - 2) * wheel)
    end

    # The string is the loop's output after the delay, average, and lowpass
    # (plus the bright burst, which goes around the string with it): the
    # clean burst only enters the delay line, so it is heard once it has
    # been through the string's damping (one period later), never raw
    string = clean.feedback { |fb, input|
      line = fb + input
      line += bright_string if bright_string
      d = line.delay(period, smoothing: false, max_delay: MAX_PLUCK_PERIOD)
      s = (d + d.delay(1.samples)) * (gain * 0.5)
      s = s.filter(:lowpass, cutoff: cutoff, quality: 0.5**0.5) if damping > 0
      s = (s * (1 + stretch)).softclip(0.3, 1) * (1.0 / (1 + stretch)) if stretch > 0
      bright_raw ? s + bright_raw : s
    }

    # The output fades in (the bright voice from the note-on over a period,
    # the clean one after its silent first period over two)
    if attack.nil?
      attack = mix.is_a?(Numeric) ? 1 + mix : mix + 1
    end
    env = pluck_output_env(v, release: release, attack: attack, attack_shape: attack_shape, delay: mix, period: period)
    env = env.legato if hammer || glide > 0

    # Makeup gain to the level of the other synth scripts (a plucked string
    # spends most of its time decaying)
    string * env * 4
  end

  # Gain of pluck_voice's bright burst at +freq+ (Hz, a node): the old
  # voice's ring is quieter at low notes (its 8 ms burst fills less of the
  # string, and most of it is above what the string keeps), so this raises
  # it to the clean voice's ring: 3.2 dB per octave below 1200 Hz, plus
  # 2.8 dB at every pitch.  Fit to the ring RMS (0.1-0.3 s, velocity 0.9,
  # power average of 12 seeds; one burst's ring varies by several dB) of
  # the clean voice minus the old bright one: 41 Hz 15.0 dB, 110 Hz 13.7,
  # 220 Hz 10.6, 440 Hz 7.9, 880 Hz 5.1, 1319 Hz 2.7.
  def self.pluck_bright_gain(freq)
    ((1200.0 / freq) ** (3.2 / 20 / Math.log10(2))).aclip(1, 100) * 2.8.db
  end

  # The picks of a string for hammer-ons (see pluck_voice): returns [a
  # trigger at every note-on and every return to a held note (a pull-off
  # when the top note is released), the pick level held from each one,
  # and 1 held from fresh picks, 0 from legato ones]: levels are 1 for a
  # note that starts with no note held, +hammer_level+ for a legato note
  # above the last one, +pull_level+ for one below (or the same).
  def self.pluck_hammer_picks(v, hammer_level:, pull_level:)
    held = v.gate.delay(1.samples, smoothing: false)
    step = v.number - v.number.delay(1.samples, smoothing: false)
    up = step.aclip(0, 1)
    trigger = ((v.trigger + step * step) * 1e6).aclip(0, 1)
    legato_level = up * (hammer_level - pull_level) + pull_level
    [trigger, (1 - held * (1 - legato_level)).sample_hold(trigger), (1 - held).sample_hold(trigger)]
  end

  # The output envelope of pluck_voice: silent for +delay+ periods (until
  # the string sounds), then a fade-in over +attack+ periods (+attack_shape+
  # :linear or :s), full level while held, and a +release+ in seconds.
  # +delay+ and +attack+ may be nodes.  Without an attack, the plain gate
  # (an amp_env with no attack).
  def self.pluck_output_env(v, release:, attack: 0, attack_shape: :linear, delay: 1, period: v.period)
    return v.amp_env(0, 0, 1, release) if attack.is_a?(Numeric) && attack <= 0

    v.amp_env([[0, period * delay, 0, :exp], [1, period * attack, 0, attack_shape == :s ? :s : :exp], [0, release]])
  end

  if main_script?(__FILE__)
    synth_script(
      sustain: [3.0, Float, '-s', 'Seconds for the string to fall 60 dB', 0.05..60.0],
      damping: [6.0, Float, '-d', 'Loop lowpass cutoff as a multiple of the pitch (0 for none; the mod wheel lowers it to 2x)', 0.0..64.0],
      bright: [false, '-b', 'The bright voice (raw 8 ms burst) at every pitch (default: bright below about --crossover Hz, clean above)'],
      clean: [false, 'The clean voice (a period of noise into the string only) at every pitch'],
      crossover: [PLUCK_CROSSOVER, Float, '-X', 'Center of the octave over which low notes\' bright voice crossfades to high notes\' clean one (Hz)', 20.0..20000.0],
      click: [1.0, Float, '-C', 'Level of the bright voice\'s raw burst against its ring (1: the old voice; 0.5: 6 dB less click)', 0.0..4.0],
      pick: [1.0, Float, '-k', 'Length of the clean voice\'s noise burst in periods of the note (1 is classic Karplus-Strong)', 0.25..8.0],
      brightness: [12.0, Float, '-B', 'Clean voice\'s noise lowpass at full velocity as a multiple of the pitch (softer notes are darker)', 0.5..64.0],
      stretch: [0.0, Float, '-t', 'Softclip drive inside the loop (0 for none; buzzy, sitar-like)', 0.0..20.0],
      brightness_hz: [0.0, Float, '-H', 'Clean voice\'s noise lowpass at full velocity in Hz instead of --brightness (0: off)', 0.0..20000.0],
      attack: [nil, Float, '-a', 'Fade the string in over this many periods (default: 1 for the bright voice, 2 for the clean one; 0 for none)', 0.0..64.0],
      attack_shape: [:linear, '-A', 'Attack fade shape', [:linear, :s]],
      glide: [0.0, Float, '-G', 'Glide time in seconds between legato notes (with --voices 1; 0 for none)', 0.0..5.0],
      hammer: [false, '-M', 'Legato notes are hammer-ons and pull-offs: the pitch jumps and the ringing string gets a small new pick (mono: one voice)'],
      hammer_level: [0.25, Float, 'Hammer-on pick level (legato notes going up) relative to a full pick', 0.0..1.0],
      pull_level: [0.12, Float, 'Pull-off pick level (legato notes going down) relative to a full pick', 0.0..1.0],
      release: [0.08, Float, '-r', 'Release time in seconds after note-off (the string is muted)', 0.0..5.0],
      voices: [6, Integer, '-v', 'Number of voices (--hammer uses one)', 1..32],
    ) { |midi, p|
      raise ArgumentError, 'Choose --bright or --clean, not both' if p.bright && p.clean
      raise ArgumentError, 'Choose --glide or --hammer, not both' if p.hammer && p.glide > 0

      voice = p.bright ? :bright : p.clean ? :clean : :auto
      midi.synth(voices: p.hammer ? 1 : p.voices) { |v|
        pluck_voice(v, sustain: p.sustain, damping: p.damping, pick: p.pick, brightness: p.brightness, stretch: p.stretch, release: p.release,
          brightness_hz: p.brightness_hz, attack: p.attack, attack_shape: p.attack_shape, glide: p.glide,
          voice: voice, crossover: p.crossover, click: p.click,
          hammer: p.hammer, hammer_level: p.hammer_level, pull_level: p.pull_level)
      }
    }
  end
end
