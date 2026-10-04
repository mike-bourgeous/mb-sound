module MB
  module Sound
    class Notes
      # Converts a note number signal plus any number of offsets in
      # semitones (numbers or graph nodes, e.g. pitch bend and vibrato) to
      # Hz through the session Tuning (MB::Sound.tuning), as it is when each
      # buffer is computed, so tuning changes apply to notes already playing
      # (like GraphNode#freq).  Used by Notes#freq and Notes::NotePitch.
      #
      # Example:
      #     Notes::Frequency.new(v.number, offsets: [v.bend_semitones, 12])
      class Frequency
        include GraphNode
        include GraphNode::SampleRateHelper

        # The note number node.
        attr_reader :number

        # The offsets in semitones (numbers or nodes).
        attr_reader :offsets

        # +number+ is a graph node of note numbers; +:offsets+ are semitones
        # to add (numbers or nodes).  +:initial+ is the note number to report
        # from #value before the first buffer.
        def initialize(number, offsets: [], initial: nil, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          @number = number.get_sampler
          @offsets = offsets.map { |o| o.respond_to?(:sample) ? o.get_sampler : o.to_f }
          @constant = @offsets.grep(Numeric).sum(0.0)
          @nodes = @offsets.reject { |o| o.is_a?(Numeric) }
          initial ||= number.respond_to?(:value) ? number.value : MB::Sound::Notes::DEFAULT_NUMBER
          @value = MB::Sound.tuning.frequency_of(initial + @constant)
          @buf = nil
          @node_type_name = 'Notes Frequency'
        end

        # The most recent frequency in Hz (the last sample of the last
        # buffer).
        attr_reader :value

        def sample(count)
          n = @number.sample(count)
          return nil if n.nil?

          count = n.length
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf[0..] = n
          @buf.inplace + @constant if @constant != 0

          @nodes.each do |node|
            o = node.sample(count)
            return nil if o.nil?
            if o.length < count
              count = o.length
              @buf = @buf[0...count].dup
            end
            @buf.inplace + o[0...count]
          end

          tuning = MB::Sound.tuning
          @buf = MB::FastSound.number_to_freq(@buf.inplace!, tuning.note, tuning.frequency)
          @buf.not_inplace!
          @value = @buf[-1]
          @buf
        end

        def sources
          s = { number: @number }
          @offsets.each_with_index { |o, idx| s[:"offset_#{idx + 1}"] = o }
          s
        end
      end
    end
  end
end
