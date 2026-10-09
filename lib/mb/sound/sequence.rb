require_relative 'sequence/duration'
require_relative 'sequence/numeric_durations'
require_relative 'sequence/event'
require_relative 'sequence/clip'
require_relative 'sequence/note_methods'
require_relative 'sequence/note_marks'
require_relative 'sequence/seq'
require_relative 'sequence/grid'
require_relative 'sequence/clip_feel'
require_relative 'sequence/generators'
require_relative 'sequence/transport'
require_relative 'sequence/timeline_node'
require_relative 'sequence/tempo_node'

module MB
  module Sound
    # Musical sequences: clips of notes with musical durations, played in a
    # node graph at a tempo.  See MB::Sound::SequenceMethods for the
    # interactive API (#seq, #grid, #rest, #bpm), Clip for combining and
    # transforming clips, and Clip#env/#tone/#gate/etc. for playing them.
    #
    # Example (bin/sound.rb):
    #     bpm 132
    #     bass = seq(C2, C2, rest, C3, C2, rest, As1, G1).n16.loop
    #     beat = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...xX').loop
    #     play(
    #       bass.tone.ramp.at(1).filter(:lowpass, cutoff: 400 + 2000 * bass.env(0.001, 0.15, 0.1, 0.05), quality: 4) * bass.env(0.005, 0.1, 0.7, 0.05) * 0.4 +
    #       50.hz.sine * beat[:kick].env(0, 0.25, 0, 0.05) +
    #       noise.filter(:highpass, cutoff: 8000) * beat[:hat].env(0, 0.03, 0, 0.02) * 0.5
    #     ).softclip
    module Sequence
      # The default Transport followed by clips (MIDI::ClipSource) and
      # tempo nodes (see MB::Sound#bpm).
      def self.transport
        @transport ||= Transport.new
      end

      # Returns an event value (a note number, or a Pitch for a fixed
      # frequency) moved by +semitones+.
      def self.transpose_value(value, semitones)
        semitones = MB::Sound::Interval.semitones(semitones)
        value.is_a?(MB::Sound::Pitch) ? value.transpose(semitones) : value + semitones
      end
    end

    Note.include(Sequence::NoteMethods)
    Note.include(Sequence::NoteMarks)

    # A rest step for MB::Sound#seq (like nil): `seq(A1, Rest, C2)`.  Alias R.
    Rest = Sequence::Seq::Step.new.freeze
    R = Rest

    # A tie step for MB::Sound#seq: holds the previous note one more step
    # (`seq(A1, Tie, Tie, C2).n16` plays A1 for three sixteenths); after a
    # rest or at the start it is a rest.  Alias T.
    Tie = Sequence::Seq::Step.new(tie: true).freeze
    T = Tie
  end
end
