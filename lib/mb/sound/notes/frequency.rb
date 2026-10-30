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
          # Steady-input cache (see #steady and GraphNode::FrozenView)
          @steady_n = GraphNode::FrozenView::Key.new
          @steady_offsets = @nodes.map { GraphNode::FrozenView::Key.new }
          @offset_bufs = Array.new(@nodes.length)
          @steady_note = nil
          @steady_frequency = nil
          @steady = nil
          @node_type_name = 'Notes Frequency'
        end

        # The most recent frequency in Hz (the last sample of the last
        # buffer).
        attr_reader :value

        #
        # While the note number and offset nodes return the same frozen
        # buffers (Notes nodes without events) and the tuning is the same,
        # returns the same frozen buffer (see Kernels.notes_fast?).
        def sample(count)
          n = @number.sample(count)
          return nil if n.nil?

          return steady(n) if Kernels.notes_fast? && n.frozen?

          compute(n)
        end

        def sources
          s = { number: @number }
          @offsets.each_with_index { |o, idx| s[:"offset_#{idx + 1}"] = o }
          s
        end

        private

        # Returns the cached frozen output if +n+ and every offset buffer are
        # the frozen buffers it was computed from, with the same generations
        # (GraphNode::FrozenView), else computes it (frozen and cached if
        # every input was frozen).
        def steady(n)
          offsets = @offset_bufs
          idx = 0
          while idx < @nodes.length
            offsets[idx] = @nodes[idx].sample(n.length)
            idx += 1
          end
          tuning = Tuning.current

          if @steady && @steady_n.match?(n) && @steady_note == tuning.note && @steady_frequency == tuning.frequency && steady_offsets?(offsets)
            return @steady
          end

          out = compute(n, offsets)
          if out && offsets.all? { |o| o&.frozen? && o.length == n.length }
            @steady_n.set(n)
            idx = 0
            while idx < offsets.length
              @steady_offsets[idx].set(offsets[idx])
              idx += 1
            end
            @steady_note = tuning.note
            @steady_frequency = tuning.frequency
            @steady = out.dup.freeze
            return @steady
          end

          @steady = nil
          out
        end

        # True if every offset buffer in +offsets+ matches its steady key.
        def steady_offsets?(offsets)
          idx = 0
          while idx < offsets.length
            return false unless @steady_offsets[idx].match?(offsets[idx])
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
          @buf = MB::Sound::Kernels.number_to_freq(@buf.inplace!, tuning.note, tuning.frequency)
          @buf.not_inplace!
          @value = @buf[-1]
          @buf
        end
      end
    end
  end
end
