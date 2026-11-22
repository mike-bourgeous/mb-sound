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

        # The new beats' knobs: energy (density, the techno beat's law: near
        # 0 the anchors, a beat's skeleton; 0.5 as written; 1 full, with the
        # kit's extra drums (crashes, toms, percussion) coming in at the
        # top; only adds hits) and swing (0.5 straight .. 0.75; home at the
        # beat's own), each read once a bar (on a track, :"drums/energy"
        # and :"drums/swing").  The kits play roles (Drums::Roles): the
        # acoustic kits' rack tom for a high tom, a 909's open hat for a
        # half-open one.  Fills are simple (snare and one tom, rising with
        # energy): the engine adds a fill's amount over its whole span, so
        # a fill over several toms would scatter instead of running high to
        # low (fill shapes are a later engine feature).
        BEAT_PARAMS = ->(seed, swing) { -> { { seed: seed, energy: (0.0..1.0).at(0.5), swing: (0.5..0.75).at(swing) } } }

        beat :rock, kit: :acoustic, tags: %i[drums backbeat straight],
          about: 'A straight-eighths rock backbeat, 90-140 BPM: low energy is the kick on 1, snare on 2 and 4, quarter hats; ' \
                 'as written the kick on 3 with pickups, ghost notes, eighth hats; high energy crashes and floor toms hammering, sixteenths, fills ' \
                 '(track :drums, kit(:acoustic); bg :drums, L.gen.beat.rock)',
          params: BEAT_PARAMS.(11, 0.5) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0.1, 0, 0, 0.25, 0, 1, 0, 0.45, 0, 0, 0.1, 0.15, 0], keep: [0], drift: 0.08
            snare [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
            row :ghost, [0, 0.08, 0, 0.12, 0, 0, 0.15, 0.08, 0, 0.12, 0, 0.15, 0, 0.08, 0, 0.2], note: 38, level: 0.25, drift: 0.1
            hat [1, 0.2, 0.95, 0.2] * 4, keep: [0, 4, 8, 12], level: 0.7, drift: 0.05
            half_open_hat [0] * 14 + [0.3, 0], level: 0.6
            # (the top of the range: crashes and a floor tom hammering; enter: thresholds later)
            crash [0.3, 0, 0, 0, 0.12, 0, 0, 0, 0.12, 0, 0, 0, 0.12, 0, 0, 0], level: 0.75
            low_floor_tom [0.2, 0, 0.1, 0] * 4, level: 0.6, drift: 0.05
            high_tom [0] * 12 + [0, 0, 0.12, 0.12], level: 0.6
            fill every: 8, last: 1.beat, energy: true, snare: 0.55, low_floor_tom: 0.3
          end
        end

        beat :pop, kit: :acoustic, tags: %i[drums backbeat four_on_the_floor],
          about: 'A four-on-the-floor pop beat, 100-128 BPM: kick on every beat, snare on 2 and 4, closed hats on the beat and half-open hats on the offbeats; ' \
                 'energy adds the offbeat hats, sixteenths, a clap on the snare, tambourine eighths, shaker sixteenths, and fills ' \
                 '(track :drums, kit(:acoustic); bg :drums, L.gen.beat.pop)',
          params: BEAT_PARAMS.(12, 0.5) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
            snare [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
            clap [0, 0, 0, 0, 0.3, 0, 0, 0] * 2, level: 0.7
            hat [1, 0.12, 0, 0.12] * 4, keep: [0, 4, 8, 12], level: 0.6, drift: 0.05
            half_open_hat [0, 0, 0.65, 0] * 4, level: 0.55
            tambourine [0.3, 0, 0.3, 0] * 4, level: 0.45, drift: 0.1
            shaker [0, 0.2] * 8, level: 0.35, drift: 0.1
            crash [0.25] + [0] * 15, level: 0.7
            fill every: 8, last: 1.beat, energy: true, snare: 0.5
          end
        end

        beat :halftime, kit: :acoustic, tags: %i[drums backbeat breakbeat],
          about: 'A half-time beat (70-90 BPM felt; DnB half-time at 170): kick on 1 with sparse pickups, snare on 3, eighth hats; ' \
                 'energy adds ghost snares, kick pickups, a ride, and fills ' \
                 '(track :drums, kit(:acoustic); bg :drums, L.gen.beat.halftime)',
          params: BEAT_PARAMS.(13, 0.5) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.35, 0, 0, 0, 0.15, 0], keep: [0], drift: 0.1
            snare [0] * 8 + [1] + [0] * 7, keep: [8]
            row :ghost, [0, 0, 0, 0.1, 0, 0, 0.12, 0, 0, 0, 0, 0.1, 0, 0.12, 0, 0.1], note: 38, level: 0.25, drift: 0.15
            hat [1, 0.08, 0.9, 0.08] * 4, keep: [0, 4, 8, 12], level: 0.65, drift: 0.05
            ride [0.12, 0, 0.12, 0] * 4, level: 0.45
            crash [0.3] + [0] * 15, level: 0.75
            low_floor_tom [0, 0, 0, 0, 0, 0, 0.15, 0, 0, 0, 0, 0, 0, 0, 0.2, 0.2], level: 0.6
            fill every: 8, last: 1.beat, energy: true, snare: 0.5, low_tom: 0.25
          end
        end

        beat :funk, kit: :acoustic, tags: %i[drums backbeat sixteenths],
          about: 'A sixteenth-note funk groove, 85-110 BPM, swing 0.54: syncopated kick (1, the "a" of 1, the "and" of 3), snare on 2 and 4 with ghosts, ' \
                 'sixteenth hats, a half-open hat on the "and" of 4; energy adds kick syncopation, ghosts, and fills ' \
                 '(track :drums, kit(:acoustic); bg :drums, L.gen.beat.funk)',
          params: BEAT_PARAMS.(14, 0.54) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0.5, 0, 0, 0.15, 0, 0, 0, 0.7, 0, 0, 0.2, 0, 0], keep: [0], drift: 0.1
            snare [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
            row :ghost, [0, 0.15, 0, 0.1, 0, 0, 0.2, 0.12, 0, 0.15, 0, 0.1, 0, 0, 0.2, 0.1], note: 38, level: 0.22, drift: 0.15
            hat [1, 0.55, 0.95, 0.55] * 4, keep: [0, 4, 8, 12], level: 0.6, drift: 0.08
            half_open_hat [0, 0, 0.12, 0, 0, 0, 0.12, 0, 0, 0, 0.12, 0, 0, 0, 0.55, 0], level: 0.55
            fill every: 8, last: 1.beat, energy: true, snare: 0.45, mid_tom: 0.2
          end
        end

        beat :house, kit: :tr909, tags: %i[drums four_on_the_floor],
          about: 'A house beat, 120-128 BPM, swing 0.58 (the 909\'s shuffle): kick on every beat, clap on 2 and 4; ' \
                 'energy adds offbeat open hats, sixteenth closed hats, a ride, and short fills ' \
                 '(track :drums, :tr909; bg :drums, L.gen.beat.house)',
          params: BEAT_PARAMS.(15, 0.58) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
            clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.85
            open_hat [0, 0, 0.85, 0] * 4, level: 0.6, drift: 0.05
            hat [0.3, 0.25, 0, 0.25] * 4, level: 0.5, drift: 0.15
            ride [0.12, 0, 0.12, 0] * 4, level: 0.4
            rimshot [0, 0, 0, 0.15, 0, 0, 0.1, 0] * 2, level: 0.5, drift: 0.1
            crash [0.15] + [0] * 15, level: 0.6
            fill every: 8, last: 1.beat, energy: true, snare: 0.4
          end
        end

        beat :dnb, kit: :acoustic, tags: %i[drums breakbeat two_step],
          about: 'A drum and bass two-step, 170-176 BPM: kick on 1 and the "and" of 3, snare on 2 and 4, ghost snares, eighth hats; ' \
                 'energy adds ghosts, a second kick, sixteenth hats, a ride, and fills ' \
                 '(bpm 174; track :drums, kit(:acoustic); bg :drums, L.gen.beat.dnb)',
          params: BEAT_PARAMS.(16, 0.5) do |seed:, energy:, swing:|
          beats(16, hold: 2, over: 4, energy: energy, swing: swing, seed: seed) do
            kick [1, 0, 0, 0, 0, 0, 0.15, 0, 0, 0, 1, 0, 0, 0, 0.15, 0], keep: [0, 10], drift: 0.08
            snare [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
            row :ghost, [0, 0, 0.1, 0.12, 0, 0, 0, 0.18, 0, 0.12, 0, 0, 0, 0.1, 0, 0.18], note: 38, level: 0.25, drift: 0.15
            hat [1, 0.2, 0.9, 0.2] * 4, keep: [0, 4, 8, 12], level: 0.6, drift: 0.08
            ride [0.1, 0, 0.25, 0] * 4, level: 0.4
            crash [0.25] + [0] * 15, level: 0.7
            fill every: 8, last: 1.beat, energy: true, snare: 0.5
          end
        end

        beat :techno, kit: :tr909, tags: %i[drums four_on_the_floor generative_steer],
          about: 'An evolving techno beat, 124-138 BPM: anchored kick and clap, drifting snare ghosts, mutating Euclidean hats and ride, a fill every 8 bars; ' \
                 'energy thins and fills it (track :drums, L.gen.beat.techno)',
          params: -> { { seed: 5, energy: (0.0..1.0).at(0.5) } } do |seed:, energy:|
          # (energy only, as shipped: a swing knob would add a knob line to
          # the sets and saves that use it; a question for the maintainer)
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
