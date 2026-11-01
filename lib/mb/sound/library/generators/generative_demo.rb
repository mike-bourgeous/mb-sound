module MB
  module Sound
    module Library
      module Generators
        # The generators of bin/songs/generative_demo.rb (G1 and G2: a
        # probability scale blending D dorian and F major at 84 BPM, a chord
        # layer on top), the song's one source: `L.gen.koto_motif` (the
        # lead with phrase memory), `L.gen.probability_melody` (G1's lead),
        # `L.gen.dorian_melody` (the older melody(vary: true)),
        # `L.gen.rin_strikes`, `L.gen.bowl_strikes`, `L.gen.chord_pad`.
        module GenerativeDemo
          extend NoteNames # (D3, A3)

          module_function

          # The chords, two bars each (D dorian, then F major, then back).
          def chord_list
            [
              [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [A2, C3, E3, G3],
              [D3, F3, A3, C4], [G2, B2, D3, F3], [E3, G3, B3, D4], [A2, C3, E3, G3],
              [D3, F3, A3, C4], [F3, A3, C4, E4], [As2, D3, F3, A3], [G2, As2, D3, F3],
              [C3, E3, G3, As3], [F3, A3, C4, E4], [As2, D3, F3, A3], [A2, C3, E3, G3],
            ]
          end

          # The key: D dorian, blending into F major over bars 13-18 and
          # back over bars 27-30, looping every 32 bars.
          def key
            MB::Sound.harmony(
              0 => MB::Sound.scale(:dorian, :d), 12.bars => MB::Sound.scale(:dorian, :d), 18.bars => MB::Sound.scale(:major, :f),
              26.bars => MB::Sound.scale(:major, :f), 30.bars => MB::Sound.scale(:dorian, :d), loop: 32.bars
            )
          end

          # The chord layer: #chord_list, two bars each, looping.
          def chords
            MB::Sound.harmony(chord_list.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 32.bars)
          end

          # The leads' and bells' probability scale: the key (blurred by
          # +blur+, 0..1) with the chord layer on top.
          def harmony(blur = 0)
            k = key
            (blur > 0 ? k.blur(blur) : k) + chords * 1.5
          end

          # The leads' register: every lead plays in it with its average
          # note near E4 (motifs around E4, melody from D4, old from the
          # root D4; 62-63 over 32 bars at seed 7), so A/B comparisons hear
          # the line, not the octave.
          def range = A3..A5
          def center = E4

          # The melodies' rhythm: five of eight eighths.
          def rhythm = MB::Sound.euclid(5, 8, A3, step: 8)
        end

        generator :koto_motif, instrument: :ambient_koto, tags: %i[ambient lead motif generative_demo],
          about: 'A tune with phrase memory: a one-bar motif in the form a a b a, b answering a and landing home, mutating every two passes ' \
                 '(D dorian into F major, A3..A5 around E4)',
          params: -> { { seed: 7, harmony: GenerativeDemo.harmony } } do |seed:, harmony:|
          motifs(harmony, 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, vary: 0.2, mutate: 0.25, evolve: 2,
            range: GenerativeDemo.range, around: GenerativeDemo.center, seed: seed)
        end

        generator :probability_melody, instrument: :ambient_koto, tags: %i[ambient lead melody generative_demo],
          about: "G1's lead: a walk on the probability scale, a new walk every bar, five of eight eighths (A3..A5 from D4)",
          params: -> { { seed: 7, harmony: GenerativeDemo.harmony } } do |seed:, harmony:|
          # (its walk drifts up from the start: D4 puts its average with the others')
          melody(harmony, rhythm: GenerativeDemo.rhythm, range: GenerativeDemo.range, start: D4, vary: true, seed: seed).loop
        end

        generator :dorian_melody, instrument: :ambient_koto, tags: %i[ambient lead melody generative_demo],
          about: 'The older melody(vary: true) on a plain D dorian scale, five of eight eighths (A3..A5)',
          params: -> { { seed: 7, scale: MB::Sound.scale(:dorian, :d) } } do |seed:, scale:|
          melody(scale, rhythm: GenerativeDemo.rhythm, range: GenerativeDemo.range, vary: true, seed: seed).loop
        end

        generator :rin_strikes, instrument: :ambient_rin, tags: %i[ambient bells strikes generative_demo],
          about: 'Rin strikes, sparse and high (A4..A6 around E5), at least four eighths apart',
          params: -> { { seed: 8, harmony: GenerativeDemo.harmony } } do |seed:, harmony:|
          strikes(harmony.over(A4..A6, around: E5, width: 7), every: 1.n8, chance: 0.2, gap: 4, length: 2.bars, seed: seed)
        end

        generator :bowl_strikes, instrument: :ambient_bowl, tags: %i[ambient bowls strikes generative_demo],
          about: 'Low singing bowls on the chord tones (D2..D4), sharpened toward the roots, a bar each',
          params: -> { { seed: 9, harmony: GenerativeDemo.key + GenerativeDemo.chords * 4 } } do |seed:, harmony:|
          strikes(harmony.over(D2..D4, around: A2, width: 6), every: 1.n2, chance: 0.45, gap: 2, sharpen: 3, note: 1.bar, seed: seed)
        end

        generator :chord_pad, instrument: :ambient_drone, tags: %i[ambient pad chords generative_demo],
          about: "Pad chords voicing each chord in D3..D4 for two bars, one of them left out by the dice now and then",
          params: -> { { seed: 10, chords: GenerativeDemo.chords } },
          describe: { chords: 'The chords (a Harmony of note lists) the pad voices' } do |seed:, chords:|
          generate(2.bars, values: (50..62).to_a, seed: seed) { |cycle, dice|
            w = chords.at(cycle * 2)
            notes = (50..62).select { |n| w[n] > 0 }
            notes = notes.reject.with_index { |_, i| i == 1 && dice.chance(0.4, :drop) }
            notes.map { |n| [0r, 2r, n, 0.35 + 0.15 * dice.rand(:vel, n)] }
          }
        end
      end
    end
  end
end
