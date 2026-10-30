#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Knob-steered generators over a form (the generative layer's phase G3;
# design/notes/generative.md, "Steering"): a dark D phrygian groove at 124
# BPM where every part is a generator and three knobs steer them:
#   :energy  the drums (beats: rows thin below 0.5 and fill above it; a
#            raised energy only adds hits) and the acid bass (rhythm: one
#            melodic row walking the chord tones)
#   :density how many notes the pluck lead's motifs play (motifs density:
#            thinned or filled around 0.5; the same density brings the same
#            notes back)
#   :wander  how far the motifs have mutated from their first form
#            (motifs mutate:)
# Each generator reads its knobs once per cycle, a beat before the cycle
# starts (its decision point), so a turn steers the next bar and a take
# replays exactly what was decided.  The intro opens with a recorded
# gesture, `turn :density, 0 => 0.2, 8.bars => 0.9`: the lead fills in
# bar by bar.  The sections turn the rest (build: energy up over 8 bars,
# the motifs wandering; breakdown: energy down; drop: everything up;
# outro: down over 4 bars).  The lead plays in one register (A3..A5
# around E4) throughout.
#
# Usage:
#     bin/songs/generative_steer.rb                       # plays live in the background session
#     bin/songs/generative_steer.rb steer.flac            # renders 32 bars to a file (-f to overwrite)
#     bin/songs/generative_steer.rb --fixed steer.flac    # the same generators with the knobs held at 0.5 (no steering)
#     bin/songs/generative_steer.rb -s 3 steer.flac       # other lines and beats, the same form
#     bin/songs/generative_steer.rb --stems stems/ steer.flac   # each track too
#     bin/songs/generative_steer.rb --help                # all options
#
# Or in bin/sound.rb, steering by hand:
#     load 'bin/songs/generative_steer.rb'
#     generative_steer(form: false)       # tracks, knobs, and the groove scene; no form
#     turn :energy, 0.9, over: 4          # a build, a bar at a time
#     turn :density, 0.15                 # the lead thins out from the next phrase
#     turn :wander, 0.8, over: 8          # the motifs drift from home...
#     turn :wander, 0                     # ...and come straight back
#     ruby track(:drums)                  # the beats(...) call as Ruby
#
# Snippets:
#     knob :energy, 0.4
#     bg :d, tr909(beats(16, hold: 2, energy: knob(:energy)) { kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]; hat euclid(10, 16), mutate: 0.5 })
#     turn :energy, 0 => 0.1, 4.bars => 0.95     # a gesture: the beat grows from nothing
#     knob :busy, 0.3
#     bg :h, tr909(generate(1.bar, busy: knob(:busy), values: [F2s]) { |cycle, dice, busy:|
#       16.times.filter_map { |i| [i * 1/16r, 1/32r, F2s, 0.6] if dice.rand(:hat, i) < busy }
#     })

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/acid'
require_relative '../synths/pluck'
require_relative '../synths/fifth_pad'

module MB::Sound
  # The piece's length in bars (the form's).
  GENERATIVE_STEER_BARS = 32

  # The chords, two bars each, looping every 8 bars: i, bII, VII, i in D phrygian.
  GENERATIVE_STEER_CHORDS = [[D3, F3, A3], [Ds3, G3, As3], [C3, Ds3, G3], [D3, F3, A3]].freeze

  # The probability scale: D phrygian with the chord layer on top.
  def self.generative_steer_harmony
    chords = harmony(GENERATIVE_STEER_CHORDS.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 8.bars)
    scale(:phrygian, :d).weights + chords * 1.5
  end

  # The drums: an evolving techno beat (anchored kick and clap, drifting
  # snare ghosts, mutating Euclidean hats and ride, a fill every 8 bars),
  # thinned and filled by +energy+.
  def self.generative_steer_beats(energy, seed:)
    beats(16, hold: 2, swing: 0.53, energy: energy, over: 4, seed: seed) do
      kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], drift: 0.1
      clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.85
      snare [0, 0, 0, 0.1, 0, 0, 0.15, 0, 0, 0.1, 0, 0, 0, 0.2, 0, 0.25], drift: 0.2, level: 0.5
      hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.7
      open_hat [0, 0, 0.8, 0] * 4, drift: 0.25, level: 0.6
      ride euclid(5, 16), mutate: 0.3, level: 0.45
      fill every: 8, snare: 0.7, low_tom: 0.35, mid_tom: 0.35
    end
  end

  # The bass: one melodic row walking the chord tones low (D2..D3),
  # steered by the same +energy+.
  def self.generative_steer_bass(h, energy, seed:)
    rhythm(h.over(D2..D3, around: A2), [1, 0, 0.35, 0.5, 0, 0.3, 0.6, 0.2] * 2, energy: energy, hold: 2, length: 1, seed: seed)
  end

  # The lead: one-bar phrases of sixteenths with phrase memory (a a b a, b
  # answering a), +density+ and +wander+ (mutation) steered.
  def self.generative_steer_lead(h, density, wander, seed:)
    motifs(h, 16, step: 1.n16, form: %i[a a b a], answer: { b: :a }, density: density, mutate: wander, vary: 0.2, evolve: 1,
      range: A3..A5, around: E4, seed: seed)
  end

  # Sets up knobs, tracks, scenes, and (with +form+) the form on the
  # current session; without a form, the build scene plays.  +steer+ false
  # holds every knob at 0.5 (the generators as unsteered, for A/B
  # listening).  Returns the clips (a Hash: drums, bass, lead, pad).
  def self.generative_steer(seed: 5, steer: true, form: true)
    bpm 124
    start = steer ? { energy: 0.3, density: 0.2, wander: 0.05 } : Hash.new(0.5)
    knob :energy, start[:energy], range: 0.0..1.0
    knob :density, start[:density], range: 0.0..1.0
    knob :wander, start[:wander], range: 0.0..1.0
    h = generative_steer_harmony

    track(:drums) { |clip| tr909(clip, shuffle: 0) * 0.8 }
    track(:bass) { |clip| acid_voice(clip, cutoff: 260, reso: 0.55, env_mod: 2.5) * 0.55 }
    track(:lead) { |clip| clip.synth(voices: 3) { |v| pluck_voice(v, sustain: 1.2, brightness: 9) }.delay(3.n16, feedback: 0.3, wet: 0.25) * 3.2 }
    track(:pad) { |clip| stereo(*fifth_pad(clip, voices: 2, cutoff: 700, release: 2)) * 0.4 }

    drums = generative_steer_beats(knob(:energy), seed: seed)
    bass = generative_steer_bass(h, knob(:energy), seed: seed + 1)
    lead = generative_steer_lead(h, knob(:density), knob(:wander), seed: seed + 2)
    pad = seq(*GENERATIVE_STEER_CHORDS).len(2.bars).loop

    scene :intro, drums: drums, lead: lead, pad: pad
    scene :build, drums: drums, bass: bass, lead: lead, pad: pad
    scene :breakdown, lead: lead, pad: pad
    scene :drop, drums: drums, bass: bass, lead: lead
    scene :outro, drums: drums, lead: lead, pad: pad

    # (the parts are full scale; 4 dB into the limiter)
    master { |mix| (mix * 4.db).limit }
    clips = { drums: drums, bass: bass, lead: lead, pad: pad }
    unless form
      go :build, at: :now
      return clips
    end

    if steer
      # The recorded gesture: the lead fills in over the intro
      turn :density, 0 => 0.2, 8.bars => 0.9
      flow do
        intro 8, energy: [0.55, over: 8]
        build 8, energy: [0.85, over: 8], wander: [0.45, over: 8]
        breakdown 4, energy: 0.1, density: [0.35, over: 2]
        drop 8, energy: 0.95, density: 0.75, wander: 0.65
        outro 4, energy: [0.2, over: 4], density: [0.2, over: 4]
      end
    else
      flow do
        intro 8
        build 8
        breakdown 4
        drop 8
        outro 4
      end
    end
    clips
  end

  if main_script?(__FILE__)
    song_script(
      bars: GENERATIVE_STEER_BARS,
      seed: [5, Integer, '-s', 'The seed of every generator (the form stays)', 0..1_000_000],
      fixed: [false, 'Hold every knob at 0.5 (no steering), for A/B listening'],
    ) { |p| generative_steer(seed: p.seed, steer: !p.fixed) }
  end
end
