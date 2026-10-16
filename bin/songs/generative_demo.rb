#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A generative ambient piece (the generative layer, phases G1 and G2; see
# design/notes/generative.md and `help :generative`): every part is a
# generator clip whose cycles are pure functions of a seed, so the piece
# seeks, replays exactly in takes, and saves as a graph document.
#
# The harmony is a probability scale: D dorian for 12 bars, blending into
# F major over bars 13-18 (pivoting on their common tones), F major to bar
# 26, back to D dorian by bar 30 (looping every 32 bars), with a chord
# layer (two bars per chord, curve: :step) weighted on top (-u blurs it, so
# a wrong note slips in now and then; none by default).  Over it:
#   lead   a koto playing a tune with phrase memory (motifs: a one-bar
#          motif in the form a a b a, b answering a and landing home, the
#          repeats varying a little, the motif mutating a step here and
#          there every two passes; realized on the harmony where each note
#          starts, so it carries through the chords and the key change)
#   bells  rin strikes, sparse, high, at least four eighths apart
#   bowls  low singing bowls on the chord tones, sharpened toward the roots
#   pad    sine drones voicing each chord (a plain generate block: the
#          chord's notes in D3..D4, one of them left out by the dice now
#          and then)
#
# Usage:
#     bin/songs/generative_demo.rb                    # plays live in the background session
#     bin/songs/generative_demo.rb gen.flac           # renders 32 bars to a file (-f to overwrite)
#     bin/songs/generative_demo.rb -s 3 gen.flac      # another seed: other lines, the same harmony
#     bin/songs/generative_demo.rb -u 0.1 gen.flac    # a light blur: wrong notes now and then
#     bin/songs/generative_demo.rb -u 0.4 gen.flac    # more wrong notes
#     bin/songs/generative_demo.rb -l melody gen.flac # the G1 lead: melody on the probability scale (a new walk every bar)
#     bin/songs/generative_demo.rb -l old gen.flac    # the lead from the library's older melody(vary: true) on a plain D dorian scale
#     (all three leads play in the same register: A3..A5, centered near E4)
#     bin/songs/generative_demo.rb -p lead gen.flac   # one part alone (lead, bells, bowls, pad)
#     bin/songs/generative_demo.rb --help             # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/generative_demo.rb'
#     generative_demo                                 # live (generative_demo(seed: 3, blur: 0.3) etc.)
#     seek 13                                         # into the key change: generators play what they'd play there
#
# Snippets to try in bin/sound.rb (after `load 'bin/synths/ambient.rb'`):
#     bpm 84
#     s = scale(:dorian, :d).weights            # a probability scale (prints as a bar chart)
#     h = s.blur(0.2) + tones(D3, F3, A3) * 2   # blurred, with a chord layer on top
#     h = s.blur(0.2) + chord(:min7, root: :d).weights * 2   # the same with a named chord (and the C)
#     chords = harmony(0 => chord(:min7, root: :d3), 2.bars => chord(:'7', root: :g2), loop: 4.bars, curve: :step)
#     bg :lead, ambient_koto_voice(melody(s.blur(0.2) + chords * 2, 8, range: A3..A5, vary: true).loop)
#     bg :lead, ambient_koto_voice(melody(h, 8, range: A3..A5, vary: true).loop)
#     bg :lead, ambient_koto_voice(motifs(h, 8, form: %i[a a b a], range: A3..A5, around: E4))   # phrase memory
#     bg :lead, ambient_koto_voice(motifs(h, 16, step: 1.n16, form: [:a, :b, :a, nil], answer: { b: :a }, mutate: 0.3, evolve: 1))
#     w = scale(:dorian, :d).weights.blend(chords, 0.4)   # blending toward a harmony gives a harmony
#     key = harmony(0 => scale(:dorian, :d), 4.bars => scale(:major, :f), loop: 8.bars)   # blends both ways
#     bg :lead, ambient_koto_voice(melody(key.blur(0.2), 8, range: A3..A5, vary: true).loop)
#     bg :bells, ambient_rin_voice(strikes(key.over(A4..A6), every: 1.n8, chance: 0.3, gap: 3))
#     bg :pad, ambient_drone_voice(generate(2.bars, values: (50..62).to_a) { |cycle, dice|
#       w = key.at(cycle * 2)                   # the harmony where the cycle starts
#       (50..62).select { |n| w[n] > 0.12 }.first(3).map { |n| [0r, 2r, n, 0.3 + 0.2 * dice.rand(n)] }
#     })
#     melody(h, 8, range: A3..A5, vary: true).to_ruby   # prints the generator back as Ruby

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/ambient'

module MB::Sound
  # The demo's length in bars (the harmony loops every 32).
  GENERATIVE_DEMO_BARS = 32

  # The demo's chords, two bars each (D dorian, then F major, then back).
  GENERATIVE_DEMO_CHORDS = [
    [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [A2, C3, E3, G3],
    [D3, F3, A3, C4], [G2, B2, D3, F3], [E3, G3, B3, D4], [A2, C3, E3, G3],
    [D3, F3, A3, C4], [F3, A3, C4, E4], [As2, D3, F3, A3], [G2, As2, D3, F3],
    [C3, E3, G3, As3], [F3, A3, C4, E4], [As2, D3, F3, A3], [A2, C3, E3, G3],
  ].freeze

  # The key: D dorian, blending into F major over bars 13-18 and back over
  # bars 27-30, looping every 32 bars.
  def self.generative_demo_key
    harmony(
      0 => scale(:dorian, :d), 12.bars => scale(:dorian, :d), 18.bars => scale(:major, :f),
      26.bars => scale(:major, :f), 30.bars => scale(:dorian, :d), loop: 32.bars
    )
  end

  # The chord layer: GENERATIVE_DEMO_CHORDS, two bars each, looping.
  def self.generative_demo_chords
    harmony(GENERATIVE_DEMO_CHORDS.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 32.bars)
  end

  # The leads' register: every lead plays in this range, centered near
  # GENERATIVE_DEMO_CENTER (so A/B comparisons hear the line, not the
  # octave).
  GENERATIVE_DEMO_RANGE = (A3..A5).freeze
  GENERATIVE_DEMO_CENTER = E4

  # The lead's line (a Clip): :motifs (phrase memory), :melody (G1's
  # melody on the probability scale +h+), or :old (melody(vary: true) on
  # plain D dorian).
  def self.generative_demo_lead(h, lead: :motifs, seed: 7)
    rhythm = euclid(5, 8, A3, step: 8)
    case lead
    when :motifs
      motifs(h, 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, vary: 0.2, mutate: 0.25, evolve: 2,
        range: GENERATIVE_DEMO_RANGE, around: GENERATIVE_DEMO_CENTER, seed: seed)
    when :melody, :new
      melody(h, rhythm: rhythm, range: GENERATIVE_DEMO_RANGE, start: GENERATIVE_DEMO_CENTER, vary: true, seed: seed).loop
    when :old
      melody(scale(:dorian, :d), rhythm: rhythm, range: GENERATIVE_DEMO_RANGE, vary: true, seed: seed).loop
    else
      raise ArgumentError, "The lead is :motifs, :melody, or :old (got #{lead.inspect})"
    end
  end

  # Starts the piece on the current session (live, or inside a render
  # block).  +seed+ picks the lines (the harmony stays), +blur+ how often
  # wrong notes play (0..1), +lead+ :motifs (phrase memory), :melody (G1's
  # melody on the probability scale), or :old (the older melody(vary: true)
  # on plain D dorian), for A/B listening, +part+ :all or one part.
  def self.generative_demo(seed: 7, blur: 0, lead: :motifs, part: :all)
    bpm 84
    key = generative_demo_key
    chords = generative_demo_chords
    h = (blur > 0 ? key.blur(blur) : key) + chords * 1.5

    line = generative_demo_lead(h, lead: lead, seed: seed)
    bells = strikes(h.over(A4..A6, around: E5, width: 7), every: 1.n8, chance: 0.2, gap: 4, length: 2.bars, seed: seed + 1)
    bowls = strikes((key + chords * 4).over(D2..D4, around: A2, width: 6), every: 1.n2, chance: 0.45, gap: 2, sharpen: 3, note: 1.bar, seed: seed + 2)
    pad = generate(2.bars, values: (50..62).to_a, seed: seed + 3) { |cycle, dice|
      w = chords.at(cycle * 2)
      notes = (50..62).select { |n| w[n] > 0 }
      notes = notes.reject.with_index { |_, i| i == 1 && dice.chance(0.4, :drop) }
      notes.map { |n| [0r, 2r, n, 0.35 + 0.15 * dice.rand(:vel, n)] }
    }

    parts = {
      lead: -> { ambient_koto_voice(line, wear: 0.25) * 1.4 },
      bells: -> { ambient_rin_voice(bells) },
      bowls: -> { ambient_bowl_voice(bowls, level: 0.1) },
      pad: -> { ambient_drone_voice(pad, level: 0.8, attack: 2.5, release: 3.5) },
    }
    # (the voices are soft; 7 dB into the limiter puts the piece near -17 LUFS)
    master { |mix| (mix * 7.db).limit }
    parts.each { |name, make| bg name, make.(), fade: 0 if part == :all || part == name }
  end

  if main_script?(__FILE__)
    song_script(
      bars: GENERATIVE_DEMO_BARS,
      seed: [7, Integer, '-s', 'The seed of every line (the harmony stays)', 0..1_000_000],
      blur: [0.0, Float, '-u', "How far the scale blurs into wrong notes", 0.0..1.0],
      lead: [:motifs, Symbol, '-l', 'The lead: motifs (phrase memory), melody (G1: a walk on the probability scale), or old (melody(vary: true) on D dorian)', [:motifs, :melody, :old]],
      part: [:all, Symbol, '-p', 'The parts to play', [:all, :lead, :bells, :bowls, :pad]],
    ) { |p| generative_demo(seed: p.seed, blur: p.blur, lead: p.lead, part: p.part) }
  end
end
