require_relative 'fast_sampler'

module MB
  module Sound
    # The sampler (see design/notes/sampler.md): Sample values played by
    # GraphNode::SamplerVoice nodes through Sampler::Instrument key maps,
    # with chop clips, SFZ import, bouncing and capture (SamplerMethods).
    module Sampler
      # Loop mode codes in the kernel's region table (see Sample::LOOP_MODES).
      LOOP_MODES = { no_loop: 0, one_shot: 1, forward: 2, ping_pong: 3, release: 4 }.freeze

      # Samples over which a re-struck voice fades its old note (1.3 ms).
      DECLICK = 64

      # The note number of a chop hit: slice +slice+ (an index into an
      # instrument's chop regions; see Sample::Slices#chop_list), +semitones+
      # above its own pitch (-64...64), backwards if +reverse+.  Numbers
      # from 128 up are above MIDI's keys, so a chop clip addresses slices
      # directly while transposing it changes only the pitch.
      def self.chop_note(slice, semitones = 0, reverse: false)
        slice = Integer(slice)
        semitones = semitones.to_f
        raise ArgumentError, "Chop slices count from 0 (got #{slice})" if slice < 0
        raise ArgumentError, "Chop hits play -64 to 63 semitones from their slice (got #{semitones})" unless semitones >= -64 && semitones < 64
        v = 128 * (2 * slice + (reverse ? 1 : 0) + 1) + 64 + semitones
        v == v.round ? v.round : v
      end

      # [slice, semitones, reversed] for a chop hit's note number, or nil
      # for a key (below 128).
      def self.chop_hit(number)
        return nil if number < 128
        q = (number / 128.0).floor
        code = q - 1
        [code / 2, number - q * 128 - 64, code.odd?]
      end

      # Clip#sampler: plays the clip on a sampler instrument.
      module ClipMethods
        # A synth playing this clip on +instrument+ (an Instrument, Sample,
        # or Slices; see MB::Sound#sampler), one voice by default.
        #
        #     bg :breaks, amen.sampler(brk)
        def sampler(instrument, voices: 1, **options, &block)
          MB::Sound.sampler(self, instrument, voices: voices, **options, &block)
        end
      end
    end
  end
end

require_relative 'sample'
require_relative 'sampler/kernel_ruby'
require_relative 'sampler/instrument'
require_relative 'sampler/sfz'
require_relative 'sampler/capture'

MB::Sound::Sequence::Clip.include(MB::Sound::Sampler::ClipMethods)
