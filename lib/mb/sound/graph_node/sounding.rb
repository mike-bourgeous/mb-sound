module MB
  module Sound
    module GraphNode
      # A gate that follows whether its source is making sound: 1 while the
      # source is above MB::Sound::QuietRun::QUIET (-90 dB) and for
      # +hold+ seconds after it falls below, then a linear fade to 0 over
      # +fade+ seconds; back to 1 on the first loud sample.  It starts
      # closed (0) until the source first sounds.  When the source ends, the
      # gate plays on as if the source were silent and ends where its fade
      # reaches 0 (at once if already closed), the way delays ring out
      # (MB::Sound::QuietRun#advance), so a graph it feeds ends after its source.
      #
      # Each sample's value depends only on how many samples have passed
      # since the source's last loud sample, so the gate (and where it ends)
      # is the same at any buffer size.
      #
      # The source may be a Channels bundle (Channels#sounding): one gate for
      # all of them, open while any channel sounds and ending once every
      # channel has ended (one tape transport for a stereo tape).
      #
      # Made by GraphNode#sounding.  Use it to stop things that should run
      # only while there is sound, like a tape's hiss (bin/synths/ambient.rb
      # #ambient_tape) or a noise floor under a recording.
      class Sounding
        include GraphNode
        include SampleRateHelper
        # (its count since the last loud sample: #carry_adopt)
        node_traits memory: :short, carry: :adopt

        # The source node (or Channels bundle).
        attr_reader :source

        # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true if
        # gate +old+ follows as many inputs.
        def carry_fits?(old)
          old.class == self.class && old.instance_variable_get(:@inputs).length == @inputs.length
        end

        # Takes over gate +old+'s count since its source's last loud sample
        # and its ending.
        def carry_adopt(old)
          NodeTraits.swap_contents(@live, old.instance_variable_get(:@live))
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@ended @done @quiet].freeze

        # How long the gate stays open after the source falls silent, and
        # the fade to 0 after that (seconds or fixed Lengths, as given).
        attr_reader :hold_length, :fade_length

        def initialize(source, hold: 1, fade: 0.5)
          [[:hold, hold], [:fade, fade]].each do |name, v|
            fixed = v.is_a?(Numeric) || (v.is_a?(MB::Sound::Length) && !v.is_a?(MB::Sound::Sequence::Duration) && v.fixed?)
            unless fixed && v.to_r >= 0
              raise ArgumentError, "Give #sounding a #{name}: >= 0 in seconds or a fixed Length (e.g. 250.ms; not a musical Duration) (got #{v.inspect})"
            end
          end

          @source = source
          @inputs = (source.is_a?(Channels) ? source.to_a : [source]).map(&:get_sampler)
          @live = Array.new(@inputs.length, true)
          @sample_rate = @inputs[0].sample_rate.to_f
          @hold_length = hold
          @fade_length = fade
          @hold_time = MB::Sound::Length::Source.new(hold)
          @fade_time = MB::Sound::Length::Source.new(fade)
          @ended = false
          @done = false
          @buf = Numo::SFloat.zeros(0)
          @seq = nil
          @node_type_name = 'Sounding'
          update_lengths
          @quiet = @hold + @fade # samples since the last loud sample (closed)
        end

        # Returns +count+ samples of the gate (fewer where it ends after the
        # source ended), or nil once it has ended.
        def sample(count)
          return nil if @done

          reads = @inputs.each_with_index.map { |src, j|
            next nil unless @live[j]

            d = src.sample(count)
            @live[j] = false if d.nil? || d.length < count # (ended: silent from here)
            d
          }.compact
          n = reads.map(&:length).max || 0
          if @live.none?
            # Every source ended (nil or a short last read): the gate plays
            # on as if they were silent, ending once closed (one short read)
            @ended = true
            if n == 0 && @quiet >= @hold + @fade
              @done = true
              return nil
            end
          end

          loud = nil
          if reads.length == 1
            loud = (reads[0].abs > MB::Sound::QuietRun::QUIET).where
          elsif n > 0
            mask = Numo::Bit.zeros(count)
            reads.each { |d| mask[0...d.length] = mask[0...d.length] | (d.abs > MB::Sound::QuietRun::QUIET) }
            loud = mask.where
          end
          return sample_loud(count, loud) if !@ended && loud && !loud.empty? && @hold >= count

          @seq = Numo::DFloat.new(count).seq if @seq.nil? || @seq.length != count
          i = @seq
          q = i + (@quiet + 1)
          if n > 0
            unless loud.empty?
              # Samples since the last loud one at or before each sample
              ones = Numo::Int32.zeros(count)
              ones[loud] = 1
              k = ones.cumsum
              seen = k.gt(0).where
              q[seen] = i[seen] - Numo::DFloat.cast(loud[k[seen] - 1])
            end
          end

          if @ended
            # Ends on the first sample after the source's end where it is closed
            closed = q[n..].ge(@hold + @fade).where
            unless closed.empty?
              count = n + closed[0] + 1
              q = q[0...count]
              @done = true
            end
          end

          @quiet = q[-1].to_i
          @buf = Numo::SFloat.zeros(count) if @buf.length != count
          @buf[true] = gate(q)
          @buf
        end

        # Changes the sample rate, keeping the hold and fade in their units.
        def sample_rate=(rate)
          old = @sample_rate
          super
          @quiet = (@quiet * @sample_rate / old).round
          update_lengths
          self
        end
        alias at_rate sample_rate=

        def sources
          return { input: @inputs[0] } if @inputs.length == 1

          @inputs.each_with_index.to_h { |s, j| [:"input_#{j}", s] }
        end

        def to_s
          "#{super} -- hold #{@hold_length}, fade #{@fade_length}"
        end

        private

        # The usual case for a sounding source, when +hold+ is at least a
        # buffer: from its first loud sample on, every gap is shorter than
        # the hold, so the gate is 1; only the samples before it can fade.
        def sample_loud(count, loud)
          first = loud[0]
          @buf = Numo::SFloat.zeros(count) if @buf.length != count
          @buf[0...first] = gate(Numo::DFloat.new(first).seq + (@quiet + 1)) if first > 0
          @buf[first..] = 1
          @quiet = count - 1 - loud[-1]
          @buf
        end

        def update_lengths
          @hold = @hold_time.constant_samples(@sample_rate).round
          @fade = @fade_time.constant_samples(@sample_rate).round
        end

        # The gate for +q+ samples since the last loud sample.
        def gate(q)
          return Numo::DFloat.cast(q.le(@hold)) if @fade == 0

          (1.0 - (q - @hold) / @fade).clip(0, 1)
        end
      end
    end
  end
end
