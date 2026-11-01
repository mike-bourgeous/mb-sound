module MB
  module Sound
    module Library
      module Generators
        # The generators of bin/songs/generative_steer.rb (G3: knob
        # steering and evolving rhythms; D phrygian at 124 BPM), the song's
        # one source: `L.gen.techno_beat`, `L.gen.acid_rhythm`,
        # `L.gen.phrygian_motif`.
        module GenerativeSteer
          extend NoteNames # (D3, A3)

          module_function

          # The chords, two bars each, looping every 8 bars: i, bII, VII, i
          # in D phrygian.
          def chords
            [[D3, F3, A3], [Ds3, G3, As3], [C3, Ds3, G3], [D3, F3, A3]]
          end

          # The probability scale: D phrygian with the chord layer on top.
          def harmony
            ch = MB::Sound.harmony(chords.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 8.bars)
            MB::Sound.scale(:phrygian, :d).weights + ch * 1.5
          end
        end

        generator :techno_beat, instrument: :tr909, tags: %i[techno drums beat generative_steer],
          about: 'An evolving techno beat: anchored kick and clap, drifting snare ghosts, mutating Euclidean hats and ride, a fill every 8 bars; ' \
                 'energy thins and fills it',
          params: -> { { seed: 5, energy: (0.0..1.0).at(0.5) } } do |seed:, energy:|
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

        generator :acid_rhythm, instrument: :acid, tags: %i[techno bass acid generative_steer],
          about: 'A one-bar bass row walking the chord tones low (D2..D3) in D phrygian; energy thins and fills it',
          params: -> { { seed: 6, harmony: GenerativeSteer.harmony, energy: (0.0..1.0).at(0.5) } } do |seed:, harmony:, energy:|
          rhythm(harmony.over(D2..D3, around: A2), [1, 0, 0.35, 0.5, 0, 0.3, 0.6, 0.2] * 2, energy: energy, hold: 2, length: 1, seed: seed)
        end

        generator :phrygian_motif, instrument: :dnb_pluck, tags: %i[techno lead motif generative_steer],
          about: 'One-bar phrases of sixteenths with phrase memory (a a b a, b answering a) in D phrygian, A3..A5 around E4',
          params: -> { { seed: 7, harmony: GenerativeSteer.harmony, density: (0.0..1.0).at(0.5), mutate: (0.0..1.0).at(0.15) } } do |seed:, harmony:, density:, mutate:|
          motifs(harmony, 16, step: 1.n16, form: %i[a a b a], answer: { b: :a }, density: density, mutate: mutate, vary: 0.2, evolve: 1,
            range: A3..A5, around: E4, seed: seed)
        end
      end
    end
  end
end
