module MB
  module Sound
    module Library
      module Generators
        # The chance clips of bin/songs/tin_roof.rb ("Tin Roof, Slow River",
        # 60 BPM, the yo pentatonic in D): a sparse koto motif and a swung
        # harp figure, each humanized, some notes by chance every pass.
        generator :tin_roof_motif, instrument: :ambient_koto, tags: %i[ambient lead motif chance tin_roof],
          about: 'A sparse kankyo motif in eighths on the yo scale in D, humanized, two notes by chance (0.6, 0.5)',
          params: -> { { seed: 0 } }, describe: { seed: "The humanize seed" } do |seed:|
          seq(
            A4, R, R, D5, R, B4, R, R,   R, R, E5.maybe(0.6), R, R, R, R, R,
            G4, R, R, A4, R, R, R, R,    R, D5, R, R, B4.maybe(0.5), R, R, R,
          ).n8.humanize(1.n64, velocity: 0.15, seed: seed).loop(align: :launch)
        end

        generator :tin_roof_harp, instrument: :ambient_harp, tags: %i[ambient arp chance tin_roof],
          about: 'A swung Karplus-Strong figure in sixteenths on the yo scale in D, humanized, two notes by chance (0.7, 0.5)',
          params: -> { { seed: 0 } }, describe: { seed: "The humanize seed" } do |seed:|
          seq(
            D5, R, A4, B4.maybe(0.7), R, D5, R, E5,  R, G4, R, R, A4.maybe(0.5), R, R, R,
          ).n16.swing(0.6).humanize(1.n128, velocity: 0.2, seed: seed).loop(align: :launch)
        end
      end
    end
  end
end
