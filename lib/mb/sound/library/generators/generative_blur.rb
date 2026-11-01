module MB
  module Sound
    module Library
      module Generators
        # The generators of bin/songs/generative_blur.rb (blur you can hear,
        # 84 BPM): `L.gen.blur_line` (a line of independent draws from a
        # blurred field) and `L.gen.blur_cloud` (the strikes whose note-ons
        # start a granular cloud's grains), the song's one source.
        module GenerativeBlur
          extend NoteNames # (D3, A3)

          # The piece's tempo.
          BPM = 84

          # Grains a second a numeric cloud may ask for.
          CLOUD_RATES = 0.5..160

          # Default settings per part (the maintainer's Listening Bench
          # picks, 2026-10-16): the line blends chord to chord over 1/4 bar
          # in two octaves with the slow key blends; the cloud blends over
          # 1/2 bar in three octaves with 1-bar key changes.  With both
          # parts the key changes are shared (1 bar, so the parts never
          # disagree on the key); chord blends and ranges stay per part.
          DEFAULTS = {
            dense: { chord_blend: 0.25, octaves: 2, transition: :slow }.freeze,
            grains: { chord_blend: 0.5, octaves: 3, transition: 1 }.freeze,
          }.freeze

          module_function

          # The field's chords, two bars each (D dorian, into F major, back).
          def chord_list
            [
              [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [F3, A3, C4, E4],
              [As2, D3, F3, A3], [C3, E3, G3, As3], [G2, B2, D3, F3], [A2, C3, E3, G3],
            ]
          end

          # The probability field at +blur+ (a FieldTimeline over A3..A5).
          # With +transition+ nil, the key blends from D dorian into F major
          # over bars 7-10 and back over bars 11-16; with a number of bars,
          # F major lands on bar 9 (the B flat chord) and D dorian comes
          # back on bar 13 (the G7), each change blended over the
          # +transition+ bars before it (0: a step).  +chord_blend+ nil or 0
          # steps from chord to chord; a number of bars (up to 2) blends
          # each chord into the next over that span before it.  +octaves+ 2
          # (A3..A5, a bell around E4) or 3 (A3..A6, around B4, a wider
          # bell).  +transition+ :slow is the same as nil.
          def field(blur, transition: nil, chord_blend: nil, octaves: 2)
            dorian = MB::Sound.scale(:dorian, :d)
            major = MB::Sound.scale(:major, :f)
            key =
              if transition.nil? || transition == :slow
                MB::Sound.harmony(0 => dorian, 6.bars => dorian, 10.bars => major, loop: 16.bars)
              elsif transition == 0
                MB::Sound.harmony(0 => dorian, 8.bars => major, 12.bars => dorian, curve: :step, loop: 16.bars)
              else
                t = transition.rationalize
                MB::Sound.harmony(0 => dorian, (8 - t).bars => dorian, 8.bars => major, (12 - t).bars => major, 12.bars => dorian, loop: 16.bars)
              end
            chords =
              if chord_blend.nil? || chord_blend == 0
                MB::Sound.harmony(chord_list.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 16.bars)
              else
                b = chord_blend.rationalize
                raise ArgumentError, "chord_blend must be 0..2 bars (got #{chord_blend})" unless b > 0 && b <= 2
                keys = chord_list.each_with_index.flat_map { |c, i| b < 2 ? [[(2 * i).bars, c], [(2 * i + 2 - b).bars, c]] : [[(2 * i).bars, c]] }
                MB::Sound.harmony(keys.to_h, loop: 16.bars)
              end
            range, around, width = octaves == 3 ? [A3..A6, B4, 10.5] : [A3..A5, E4, 7]
            ((blur > 0 ? key.blur(blur) : key) + chords * 1.5).over(range, around: around, width: width)
          end

          # The field of +part+ (:dense or :grains) at its DEFAULTS and
          # +blur+.
          def part_field(part, blur = 0.03)
            d = DEFAULTS.fetch(part)
            field(blur, transition: d[:transition], chord_blend: d[:chord_blend], octaves: d[:octaves])
          end

          # The strike grid, chance, grain size (seconds), and gain of a
          # cloud of +rate+ grains a second: the coarsest of 128ths, 256ths,
          # and 512ths at 84 BPM (44.8, 89.6, 179.2 slots a second) where
          # the chance stays at most 0.9; grains 350 ms long (the dense
          # cloud's) up to 40 a second and 14 / rate seconds above, so about
          # 14 overlap at most (Grains holds 32); and the dense cloud's 0.2
          # gain times sqrt(14 / overlap) (overlap at least 1), the level of
          # random-phase grains summed.
          def cloud_settings(rate)
            unless rate.is_a?(Numeric) && CLOUD_RATES.cover?(rate)
              raise ArgumentError,
                "cloud is :dense, :sparse, or grains a second from #{CLOUD_RATES.begin} to #{CLOUD_RATES.end} (got #{rate.inspect})"
            end

            whole = MB::Sound::Sequence::TempoMap.seconds_at(1.0, BPM)
            division = [128, 256, 512].find { |n| rate / (n / whole) <= 0.9 } || 512
            size = [0.35, 14.0 / rate].min
            overlap = [rate * size, 1.0].max
            { division: division, chance: rate / (division / whole), size: size, gain: 0.2 * Math.sqrt(14.0 / overlap) }
          end
        end

        generator :blur_line, instrument: :marimba, tags: %i[ambient line strikes blur generative_blur],
          about: 'A line of independent draws, a note every 64th, from a blurred D dorian / F major field (A3..A5): blur you can hear',
          params: -> { { seed: 3, harmony: GenerativeBlur.part_field(:dense), division: 64 } },
          describe: { division: 'Notes per whole note (16: sixteenths, 64: sixty-fourths)' } do |seed:, harmony:, division:|
          strikes(harmony, every: Rational(1, division).whole, chance: 1, gap: 1, sharpen: 1, velocity: 0.45..0.8, seed: seed)
        end

        generator :blur_cloud, instrument: :chime, tags: %i[ambient cloud strikes blur generative_blur],
          about: "The note-ons of a granular cloud, 120 a second, from a blurred field in three octaves (A3..A6): each starts a grain at its pitch",
          params: -> {
            c = GenerativeBlur.cloud_settings(120)
            { seed: 4, harmony: GenerativeBlur.part_field(:grains), every: Rational(1, c[:division]).whole, chance: c[:chance] }
          },
          describe: { every: 'The strike grid' } do |seed:, harmony:, every:, chance:|
          strikes(harmony, every: every, chance: chance, gap: 1, sharpen: 1, seed: seed)
        end
      end
    end
  end
end
