#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Blur you can hear (the generative layer; design/notes/generative.md):
# a blurred probability scale leaks a little weight to the semitones next
# to its notes, so "wrong" notes sometimes win.  In a sparse melody that is
# a rare passing color; here every note is a fresh draw from the field, many
# times a second, so the blur's share of wrong notes is easy to hear.
#
# The field: D dorian for 6 bars, blending into F major over bars 7-10,
# then back to D dorian over bars 11-16 (looping every 16 bars), plus the
# chord of the moment (two bars each) weighted 1.5, blurred by -u, over
# A3..A5 with a bell around E4.
#   dense   a sixteenth-note line: every sixteenth a note drawn from the
#           field by weight (strikes with chance 1, gap 1), a soft
#           triangle pluck in a small room
#   grains  a granular cloud of one sustained tone (a second of triangle
#           and octave sine on D4): every grain starts on a note-on of a
#           generator drawing a note from the field by weight (about 8 a
#           second, Poisson-like: chance 0.7 per thirty-second), and plays
#           at that note's pitch, so each grain's pitch is one draw from
#           the probability scale
#
# Usage:
#     bin/songs/generative_blur.rb                            # dense, blur 0.15, live
#     bin/songs/generative_blur.rb -u 0 blur.flac             # no blur: only scale and chord notes
#     bin/songs/generative_blur.rb -u 0.4 blur.flac           # many wrong notes
#     bin/songs/generative_blur.rb -m grains -u 0.4 blur.flac # the granular cloud
#     bin/songs/generative_blur.rb -m both blur.flac          # both together
#
# Or in bin/sound.rb:
#     load 'bin/songs/generative_blur.rb'
#     generative_blur(mode: :grains, blur: 0.3)
#
# Snippets (after `load 'bin/songs/generative_blur.rb'`):
#     f = (scale(:dorian, :d).weights.blur(0.3) + chord(:min7, root: :d).weights).over(A3..A5, around: E4, width: 7)
#     puts f                                                  # the field as a bar chart: the blurred semitones are the short bars
#     line = strikes(f, every: 1.n16, chance: 1, gap: 1, sharpen: 1)
#     bg :dense, line.synth(voices: 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) }.at(-18.db)
#     n = strikes(f, every: 1.n32, chance: 0.7, gap: 1, sharpen: 1).notes
#     tone = bounce(1.seconds, root: D4) { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
#     bg :cloud, tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.3, size: 150.ms, normalize: false).at(-12.db)

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/ambient'

module MB::Sound
  # The piece's length in bars (the field loops every 16).
  GENERATIVE_BLUR_BARS = 16

  # The field's chords, two bars each (D dorian, into F major, back).
  GENERATIVE_BLUR_CHORDS = [
    [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [F3, A3, C4, E4],
    [As2, D3, F3, A3], [C3, E3, G3, As3], [G2, B2, D3, F3], [A2, C3, E3, G3],
  ].freeze

  # The probability field at +blur+ (a FieldTimeline over A3..A5).
  def self.generative_blur_field(blur)
    key = harmony(0 => scale(:dorian, :d), 6.bars => scale(:dorian, :d), 10.bars => scale(:major, :f), loop: 16.bars)
    chords = harmony(GENERATIVE_BLUR_CHORDS.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 16.bars)
    ((blur > 0 ? key.blur(blur) : key) + chords * 1.5).over(A3..A5, around: E4, width: 7)
  end

  # Starts the piece on the current session (live, or in a render block).
  # +mode+ :dense, :grains, or :both; +blur+ 0..1; +seed+ the draws.
  def self.generative_blur(mode: :dense, blur: 0.15, seed: 3)
    bpm 84
    field = generative_blur_field(blur)

    if mode == :dense || mode == :both
      line = strikes(field, every: 1.n16, chance: 1, gap: 1, sharpen: 1, velocity: 0.45..0.8, seed: seed)
      pluck = line.synth(voices: 6) { |v| v.hz.triangle * v.env(0.002, 0.25, 0, 0.1) * (v.velocity * 0.6 + 0.4) }
      bg :dense, ambient_room(pluck.lp4(3500), space: 0.35, decay: 3, room_size: 0.5).pan(-0.1), fade: 0
    end

    if mode == :grains || mode == :both
      tone = bounce(1.seconds, root: D4, name: 'tone') { D4.triangle * 0.6 + D4.transpose(12).sine * 0.2 }
      n = strikes(field, every: 1.n32, chance: 0.7, gap: 1, sharpen: 1, seed: seed + 1).notes
      cloud = tone.grains(freq: n.freq, trigger: n.trigger, density: 0, position: 0.3, spread: 0.1, size: 150.ms,
        pan_spread: 0.8, normalize: false, seed: seed + 2)
      bg :grains, ambient_room(cloud.lp4(4000) * 0.3, space: 0.5, decay: 5, room_size: 0.8), fade: 0
    end

    master { |mix| (mix * 6.db).limit }
  end

  if main_script?(__FILE__)
    song_script(
      bars: GENERATIVE_BLUR_BARS,
      mode: [:dense, Symbol, '-m', 'dense (a sixteenth-note line), grains (a cloud), or both', [:dense, :grains, :both]],
      blur: [0.15, Float, '-u', 'How far the scale blurs into wrong notes', 0.0..1.0],
      seed: [3, Integer, '-s', 'The seed of the draws', 0..1_000_000],
    ) { |p| generative_blur(mode: p.mode, blur: p.blur, seed: p.seed) }
  end
end
