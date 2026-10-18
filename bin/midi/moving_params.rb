#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# MIDI transforms with parameters that move (MIDI::Param, midi-consol-2):
# a riff through humanize, swing, chance, transpose, arp, and ratchet whose
# settings follow MIDI controllers, knobs, tempo LFOs, and clips, read once
# per note (or step, or bar).
#
# Examples (-e):
# - cc_feel: humanize, swing, and chance steered by controllers 1-4.  Live,
#   turn CC 1-4 on a controller connected to the console's MIDI port (a
#   cc(...) param reads the transform's own input first, then the
#   Session's MIDI input); rendered, -c sets their resting values (0..127).
# - clip_transpose: the riff moved by a clip of steps, one per bar
#   (`transpose(seq(0, 5, -2, 3).n1.loop)`), as a stream and as a clip.
# - lfo_swing: swing breathing with a 4-bar tempo LFO (`swing(4.bars.lfo
#   .triangle.at(0.5..0.68))`).
# - knob_arp: an arpeggiator whose rate a knob picks
#   (`arp(:up, knob(:rate).choose(8, 16, 32))`), turned across the song;
#   ratchets per step from a knob too.
# - all: each in turn, 4 bars apiece.
#
# Usage:
#     bin/midi/moving_params.rb                       # plays all live
#     bin/midi/moving_params.rb -e cc_feel -c 100 out.flac
#     bin/midi/moving_params.rb -e knob_arp out.flac
#
# Snippets for bin/sound.rb (play a keyboard into the console's MIDI port):
#     pluck = proc { |v| MB::Sound.params_pluck(v) }
#     bg :keys, midi.swing(cc(1, 0.5..0.7)).humanize(cc(2, 0..0.02)).synth(voices: 8, &pluck)
#     bg :keys, midi.transpose(seq(0, 5, -2, 3).n1.loop).synth(voices: 8, &pluck)
#     knob :rate, 0.5; bg :keys, midi.arp(:up, knob(:rate).choose(8, 16, 32)).synth(voices: 8, &pluck)
#     turn :rate, 1, over: 4                          # the arp speeds up over 4 bars
#     bg :keys, midi.chance(0.4 + 0.6 * 2.bars.lfo.at(0..1)).synth(voices: 8, &pluck)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The examples of bin/midi/moving_params.rb.
  MOVING_PARAMS_EXAMPLES = [:all, :cc_feel, :clip_transpose, :lfo_swing, :knob_arp].freeze

  # A short plucked saw.
  def self.params_pluck(v, cutoff: 700, decay: 0.4, level: 1.0)
    v.hz.ramp
      .filter(:lowpass, cutoff: v.cutoff(cutoff, env: v.filt_env(0.001, 0.25, 0, 0.2, depth: 3)), quality: 2) *
      v.amp_env(0.002, decay, 0, 0.25) * level
  end

  # The riff the examples move.
  def self.params_riff
    seq(A3, C4, E4, G4, A4, G4, E4, C4).n16.loop
  end

  # Starts +example+ (see MOVING_PARAMS_EXAMPLES) on the current session;
  # +rest+ is the resting raw value of the controllers of :cc_feel.
  def self.moving_params(example: :all, rest: 64)
    bpm 108
    riff = params_riff
    pluck = proc { |v| params_pluck(v) }
    master { |mix| mix.reverb(:room, wet: -14.db).softclip(0.6, 0.98) }

    parts = {
      cc_feel: -> {
        riff.stream
          .humanize(cc(1, 0..0.03, default: rest), velocity: cc(2, 0..0.4, default: rest), seed: 3)
          .swing(cc(3, 0.5..0.7, default: rest))
          .chance(cc(4, 0.3..1, default: rest), seed: 4)
          .synth(voices: 8, &pluck)
      },
      clip_transpose: -> {
        steps = seq(0, 5, -2, 3).n1.loop
        riff.stream.transpose(steps).synth(voices: 8, &pluck) +
          riff.transpose(steps).transpose(-12).synth(voices: 4) { |v| params_pluck(v, cutoff: 300, level: 0.8) }
      },
      lfo_swing: -> {
        riff.stream.swing(4.bars.lfo.triangle.at(0.5..0.68)).synth(voices: 8, &pluck)
      },
      knob_arp: -> {
        knob :rate, 0, range: 0..1
        knob :hits, 0, range: 1..3
        chords = (seq(A3, F3, C4, G3).n1 & seq(C4, A3, E4, B3).n1 & seq(E4, C4, G4, D4).n1).legato(0.95).loop
        chords.stream
          .arp(:updown, knob(:rate).choose(8, 16, 32), octaves: 2, gate: 0.6)
          .ratchet(knob(:hits).choose(1, 2), rate: 1.n32)
          .synth(voices: 8) { |v| params_pluck(v, cutoff: 1200, decay: 0.2, level: 1.2) }
      },
    }

    turns = -> {
      at_bar(2) { turn :rate, 0.5 }
      at_bar(3) { turn :rate, 1; turn :hits, 3 }
      at_bar(4) { turn :rate, 0.5, over: 1 }
    }

    if example != :all
      bg example, parts.fetch(example).call, fade: 0
      turns.call if example == :knob_arp
      return
    end

    names = MOVING_PARAMS_EXAMPLES - [:all]
    names.each_with_index do |name, i|
      at_bar(1 + 4 * i) {
        bg name, parts[name].call, fade: 0
        stop names[i - 1], fade: 1/4r if i > 0
      }
    end
    at_bar(13) {
      at_bar(14) { turn :rate, 0.5 }
      at_bar(15) { turn :rate, 1; turn :hits, 3 }
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: 16,
      example: [:all, Symbol, '-e', 'The example to play', MOVING_PARAMS_EXAMPLES],
      cc: [64, Integer, '-c', 'Resting value (0..127) of the controllers of cc_feel when nothing moves them', 0..127],
    ) { |p| moving_params(example: p.example, rest: p.cc) }
  end
end
