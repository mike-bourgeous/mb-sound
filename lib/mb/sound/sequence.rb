require_relative 'sequence/duration'
require_relative 'sequence/event'
require_relative 'sequence/clip'
require_relative 'sequence/seq'
require_relative 'sequence/note_methods'
require_relative 'sequence/grid'

module MB
  module Sound
    # Musical sequences: clips of notes with musical durations.  See
    # MB::Sound::SequenceMethods for the interactive API (#seq, #grid, #rest)
    # and Clip for combining and transforming clips.
    #
    # Example (bin/sound.rb):
    #     bass = seq(C2, C2, rest, C3, C2, rest, As1, G1).n16
    #     beat = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...xX')
    module Sequence
    end

    Note.include(Sequence::NoteMethods)
  end
end
