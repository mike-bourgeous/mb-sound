#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Kaede Rowntree's ambient instruments from "Tin Roof, Slow River" (bin/songs/tin_roof.rb), playable from MIDI.
#
# Kaede Rowntree is a fictional piano tuner turned field recordist (zen
# ambient soundscapes) from the persona panel experiment of 2026-10-13
# (research branch research-persona-zen, research/persona-panel/zen/), who
# wrote the song with the public API; the instruments moved here so they can
# be played, reused, and saved as presets.  The weather (rain, river) stays
# in the song.
#
# Patches (-p):
#   bowl      a singing bowl struck at each note-on (velocity is the
#             force): four partials at bowl-like inharmonic ratios, each a
#             doublet beating (--beat Hz apart), higher ones dying sooner,
#             in a long soft room (--space)
#   rin       a small high bowl: faster beating, a shorter room
#   gong      a tam-tam: dense low partials gliding down after the stroke
#             and a high shimmer swelling in over seconds (D2 plays 55 Hz;
#             other notes transpose it)
#   epiano    a soft FM e-piano (1:1 body, faint 7:1 tine) through worn tape
#             (--wear) and a room
#   harp      Karplus-Strong plucks (bin/synths/pluck.rb), soft, through the
#             tape and a room
#   drone     two old sine generators per side (root, fifth, octave)
#             drifting fractions of a hertz, beating
#   rainstick a rain stick tipped over for each note: clicks swelling and
#             fading over the note, moving right to left
#
# Every patch is one method taking a MIDI source (Notes, Clip, MIDI file, or
# Stream) and its knobs as keywords: kaede_bowl_voice(midi, space:),
# kaede_rin_voice, kaede_gong_voice, kaede_epiano_voice(midi, wear:, space:),
# kaede_harp_voice, kaede_drone_voice, kaede_rainstick_voice; the effects
# kaede_tape(sig, wear:) and kaede_room(sig, space:) stand alone too.  Each
# is also a preset (presets/kaede_*.mbg.rb): `preset :kaede_bowl, midi: midi`,
# `preset :kaede_tape, input: mic, wear: 0.7`.
#
# Usage:
#     bin/synths/kaede_rowntree.rb                           # live MIDI, the bowls
#     bin/synths/kaede_rowntree.rb -p gong song.mid gong.flac
#     bin/synths/kaede_rowntree.rb -p epiano -w 0.8 song.mid worn.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/kaede_rowntree.rb'`):
#     bpm 60
#     bg :bowls, kaede_bowl_voice(seq(D3.n1, A3.n1, R.n1, G3.n2, B3.n2).loop)
#     bg :drone, kaede_drone_voice(seq(D2.n1).loop) * 1.5
#     bg :keys, kaede_epiano_voice(seq(A4, R, R, D5, R, B4, R, R).n8.humanize(1.n64).loop, wear: 0.4)
#     play 440.hz.square.then { |s| kaede_tape(s * 0.1, wear: 0.9) }   # the tape alone

require 'bundler/setup'
require 'mb-sound'
require_relative 'pluck'

module MB::Sound
  # A dust generator: sparse single-sample impulses with random heights
  # (0..1), about +rate+ per second, from uniform noise above a threshold.
  def self.kaede_dust(rate)
    p = rate / 48000.0
    (noise.aabs - (1 - p)).aclip(0, nil) * (1 / p)
  end

  # A slow random walk between +lo+ and +hi+: a new random target +rate+
  # times a second, glided over one step.
  def self.kaede_walk(rate, lo, hi)
    rate.hz.lfo.square.sample_hold.smooth(1.0 / rate).at(lo..hi)
  end

  # A singing bowl struck by +strike+ (impulses; their heights are the
  # force) at +freq+ (Hz, a number or a node): four partials at bowl-like
  # inharmonic ratios, each a doublet a little apart (+beat+ Hz for the
  # first, wider above: beating), higher partials dying sooner (+decay+
  # seconds for the first).  +flat+ in cents.
  def self.kaede_bowl(strike, freq, flat: 0, decay: 24, beat: 0.7)
    freq *= 2 ** (-flat / 1200.0)
    [[1.0, 1.0, 1.0], [2.77, 0.45, 0.46], [5.15, 0.22, 0.25], [8.1, 0.1, 0.15]].map.with_index { |(r, amp, dec), i|
      b = beat * (i + 1) ** 1.3
      strike.ping(freq * r, decay: decay * dec) * amp + strike.ping(freq * r + b, decay: decay * dec * 0.8) * (amp * 0.7)
    }.reduce(:+)
  end

  # Dry stereo +sig+ plus a reverb of it scaled by +space+ (a number or a
  # node): the reverb is wet-only, so a knob can scale it.  The dry part
  # waits in silence for the reverb's tail (a sum ends when any of its
  # inputs ends).
  def self.kaede_room(sig, space: 0.5, decay: 8, room_size: 0.9)
    wet = sig.reverb(room_size: room_size, decay: decay, damping: 0.55, predelay: 0.03, dry: 0, wet: 1)
    sig.and_then(silence(decay * 2)) + wet * space
  end

  # Tape wear (+wear+ 0..1, a number or a node): wow (a slowly wandering
  # delay), a lowpass that falls, and sample-rate crush that grows with
  # wear.
  def self.kaede_tape(sig, wear: 0)
    wow = sig.delay(0.37.hz.lfo.sine.at(0.006..0.009) + kaede_walk(1.3, -0.0007, 0.0007))
    dark = wow.filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
    dark.decimate(16000 - wear * 11000, mix: wear * 0.6)
  end

  # Singing bowls struck at each note-on (velocity is the force), panned
  # at +pan+, in a long soft room (+space+, +room+ seconds of decay).
  def self.kaede_bowl_voice(midi, flat: 0, decay: 24, beat: 0.7, level: 0.12, pan: 0, space: 0.5, room: 9, voices: 6)
    bowls = synth(midi, voices: voices) { |v| kaede_bowl(v.trigger, v.freq, flat: flat, decay: decay, beat: beat) }
    kaede_room((bowls * level).pan(pan), space: space, decay: room)
  end

  # A small rin (high bowl): faster beating, a shorter room.
  def self.kaede_rin_voice(midi, flat: 0, decay: 24, beat: 1.6, level: 0.08, pan: 0.15, space: 0.5, room: 7, voices: 4)
    kaede_bowl_voice(midi, flat: flat, decay: decay, beat: beat, level: level, pan: pan, space: space, room: room, voices: voices)
  end

  # A tam-tam: dense low inharmonic partials (from +freq+ Hz at D2,
  # following the note) gliding down a little after the stroke (a
  # flat-centered gong), and a high shimmer swelling in over a couple of
  # seconds (energy cascading up), then fading; in a big room.
  def self.kaede_gong_voice(midi, freq: 55.0, glide: 0.05, shimmer: 0.07, space: 0.5)
    gong = synth(midi, voices: 1) { |n|
      hit = n.trigger
      fall = adsr(0, 4, 0, 0, trigger: hit, curve: :linear)
      f = freq * 2 ** ((n.number - D2.number) / 12.0)
      ratios = [1.0, 1.47, 2.02, 2.51, 2.97, 3.58, 4.23, 5.06, 5.91, 6.8]
      low = ratios.map.with_index { |r, i|
        hit.ping(f * r * (1 + fall * glide), decay: 24.0 / (1 + i * 0.35)) * (0.6 / (1 + i * 0.25))
      }.reduce(:+)
      swell = n.env(2.2, 7, 0, 3, curve: :swell, gm: false)
      air = noise.filter(:bandpass, cutoff: kaede_walk(0.7, 2400, 5200), quality: 1.5) * swell * shimmer
      low = low.filter(:highpass, cutoff: 38, quality: 0.6) * 0.12
      stereo(low, low) + air.pan(0.2)
    }
    kaede_room(gong, space: space, decay: 10, room_size: 1.0)
  end

  # A soft FM e-piano for a kankyō motif: a sine carrier, a 1:1 modulator
  # whose index falls (the body), and a faint 7:1 tine; through worn tape
  # (+wear+) and a small room (+space+).
  def self.kaede_epiano_voice(midi, wear: 0, space: 0.5, level: 0.11, pan: -0.15)
    keys = synth(midi, voices: 4) { |v|
      body = v.hz.transpose(0).sine.at(0.9) * v.env(0.002, 1.8, 0.15, 1.5, gm: false)
      tine = v.hz.transpose(12 * Math.log2(7)).sine.at(0.25) * v.env(0.001, 0.25, 0, 0.2, gm: false)
      v.hz.pm(body + tine) * v.env(0.004, 3.2, 0.0, 1.6, gm: false) * (v.velocity * 0.5 + 0.5)
    }
    kaede_room(kaede_tape(keys * level, wear: wear).pan(pan), space: space, decay: 6, room_size: 0.7)
  end

  # The harp: soft Karplus-Strong plucks (MB::Sound.pluck_voice), through
  # worn tape (+wear+) and a small room (+space+).
  def self.kaede_harp_voice(midi, wear: 0, space: 0.5, level: 0.14, pan: 0.3, sustain: 2.5, brightness: 5)
    harp = synth(midi, voices: 3) { |v| pluck_voice(v, sustain: sustain, brightness: brightness) }
    kaede_room(kaede_tape(harp * level, wear: wear).pan(pan), space: space, decay: 5, room_size: 0.6)
  end

  # Two old sine generators per side on +root+ (Hz, a number or a node):
  # the root, a fifth (+0.31 Hz), and an octave, each drifting by a slow
  # random walk (a fraction of a hertz) and beating against the others; a
  # little warmth, a 900 Hz lowpass.  Stereo.
  def self.kaede_drone(root, level: 1.0)
    side = ->(spread) {
      gen = ->(f, depth) { (f + kaede_walk(0.05, -depth, depth)).tone.sine }
      sig = gen.(root * 1.0, 0.15 + spread) * 0.5 + gen.(root * 2 ** (7 / 12.0) + 0.31, 0.2) * 0.3 + gen.(root * 2.0 - (0.17 + spread), 0.25) * 0.18
      sig.softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6)
    }
    stereo(side.(0.0), side.(0.05)) * level * 0.18
  end

  # The drone played from MIDI: .kaede_drone on each note, swelling in
  # over +attack+ seconds and out over +release+.
  def self.kaede_drone_voice(midi, level: 1.0, attack: 3.0, release: 4.0, voices: 3)
    synth(midi, voices: voices) { |v|
      kaede_drone(v.freq, level: level) * v.env(attack, 0, 1, release, curve: :gentle, gm: false)
    }
  end

  # A rain stick tipped over for each note: clicks whose density follows
  # a slow swell over +tip+ seconds, bright pings at random pitches,
  # moving right to left across the field over +across+ seconds.
  def self.kaede_rainstick_voice(midi, tip: 2.8, across: 9, level: 1.6)
    stick = synth(midi, voices: 1) { |n|
      swell = n.env(tip, 5, 0, 1.5, curve: :gentle, gm: false)
      clicks = kaede_dust(700)
      pitch = noise.sample_hold(clicks) * 1800 + 4200
      where = adsr(0, across, 0, 0, trigger: n.trigger, curve: :linear) * 1.4 - 0.7 # right to left
      (clicks.ping(pitch, decay: 0.012) * 0.25 * swell).pan(where)
    }
    stick * level
  end

  # The script's instruments by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  def self.kaede_rowntree_patch(midi, patch = :bowl, space: 0.5, wear: 0.0)
    case patch
    when :bowl then kaede_bowl_voice(midi, space: space.constant.named('space'))
    when :rin then kaede_rin_voice(midi, space: space.constant.named('space'))
    when :gong then kaede_gong_voice(midi, space: space.constant.named('space'))
    when :epiano then kaede_epiano_voice(midi, wear: wear.constant.named('wear'), space: space.constant.named('space'))
    when :harp then kaede_harp_voice(midi, wear: wear.constant.named('wear'), space: space.constant.named('space'))
    when :drone then kaede_drone_voice(midi)
    when :rainstick then kaede_rainstick_voice(midi)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  if main_script?(__FILE__)
    synth_script(
      patch: [:bowl, Symbol, '-p', 'Instrument to play', [:bowl, :rin, :gong, :epiano, :harp, :drone, :rainstick]],
      space: [0.5, Float, '-s', 'Room level 0..1 (bowls, rin, gong, e-piano, harp)', 0.0..1.0],
      wear: [0.0, Float, '-w', 'Tape wear 0..1 (e-piano, harp)', 0.0..1.0],
    ) { |midi, p|
      kaede_rowntree_patch(midi, p.patch, space: p.space, wear: p.wear)
    }
  end
end
