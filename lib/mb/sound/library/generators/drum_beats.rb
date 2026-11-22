module MB
  module Sound
    module Library
      module Generators
        # The drum beat generators, L.gen.beat (drum-gen-1, 2026-11-22; the
        # maintainer: "families: L.gen.beat.rock"): rows of drum roles on
        # `beats`, each steered by the track knobs energy and swing.
        #
        #     track :drums, kit(:acoustic)
        #     bg :drums, L.gen.beat.rock
        #     turn :"drums/energy", 2.bars.lfo.square.at(0.2..1)

        beat :techno, kit: :tr909, tags: %i[drums four_on_the_floor generative_steer],
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
      end
    end
  end
end
