module MB
  module Sound
    module Library
      module Generators
        # The generator of bin/songs/midi_transforms_song.rb (112 BPM, A
        # minor): its bass line, a melody that varies every loop.
        generator :pentatonic_bass, instrument: :square_bass, tags: %i[bass melody midi_transforms_song],
          about: 'A bass line on A minor pentatonic (E1..A2) over a Euclidean rhythm (5 and 3 of 8), a new line every loop',
          params: -> { { seed: 7, scale: MB::Sound.scale(:minor_pentatonic, A1), leap: 2 } } do |seed:, scale:, leap:|
          rhythm = euclid(5, 8, A1, velocity: 0.8) | euclid(3, 8, A1, rotate: 1, velocity: 0.7)
          melody(scale, rhythm: rhythm, leap: leap, range: E1..A2, seed: seed, vary: true).loop
        end
      end
    end
  end
end
