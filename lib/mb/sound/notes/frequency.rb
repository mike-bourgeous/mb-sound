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

        #
        # While the note number and offset nodes return the same frozen
        # buffers (Notes nodes without events) and the tuning is the same,
        # returns the same frozen buffer (see Notes.fast_paths).
        def sample(count)
          n = @number.sample(count)
          return nil if n.nil?

          return steady(n) if Notes.fast_paths && n.frozen?

          compute(n)
        end

        def sources
          s = { number: @number }
          @offsets.each_with_index { |o, idx| s[:"offset_#{idx + 1}"] = o }
          s
        end

        private

        # Returns the cached frozen output if +n+ and every offset buffer are
        # the frozen buffers it was computed from, else computes it (frozen
        # and cached if every input was frozen).
        def steady(n)
          offsets = @nodes.map { |node| node.sample(n.length) }
          tuning = Tuning.current

          key = @steady_key
          if key && key[0].equal?(n) && key[1] == tuning.note && key[2] == tuning.frequency && same_buffers?(offsets, key[3])
            return @steady
          end

          out = compute(n, offsets)
          if out && offsets.all? { |o| o.frozen? && o.length == n.length }
            @steady_key = [n, tuning.note, tuning.frequency, offsets]
            @steady = out.dup.freeze
            return @steady
          end

          @steady_key = nil
          out
        end

        # True if Arrays +a+ and +b+ hold the same objects (without an
        # Enumerator per call).
        def same_buffers?(a, b)
          return false unless a.length == b.length
          idx = 0
          while idx < a.length
            return false unless a[idx].equal?(b[idx])
            idx += 1
          end
          true
        end

        # Computes the frequencies from note number buffer +n+ and the offset
        # nodes' buffers (sampled here unless given as +offsets+).
        def compute(n, offsets = nil)
          count = n.length
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf[0..] = n
          @buf.inplace + @constant if @constant != 0

          @nodes.each_with_index do |node, idx|
            o = offsets ? offsets[idx] : node.sample(count)
            return nil if o.nil?
            if o.length < count
              count = o.length
              @buf = @buf[0...count].dup
            end
            @buf.inplace + o[0...count]
          end

          tuning = Tuning.current
          @buf = MB::FastSound.number_to_freq(@buf.inplace!, tuning.note, tuning.frequency)
          @buf.not_inplace!
          @value = @buf[-1]
          @buf
        end
      end
    end
  end
end
