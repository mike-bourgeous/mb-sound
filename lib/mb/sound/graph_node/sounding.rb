module MB
  module Sound
    module GraphNode
      # A gate that follows whether its source is making sound: 1 while the
      # source is above MB::Sound::RingOut::THRESHOLD (-90 dB) and for
      # +hold+ seconds after it falls below, then a linear fade to 0 over
      # +fade+ seconds; back to 1 on the first loud sample.  It starts
      # closed (0) until the source first sounds.  When the source ends, the
      # gate plays on as if the source were silent and ends where its fade
      # reaches 0 (at once if already closed), the way delays ring out
      # (MB::Sound::RingOut), so a graph it feeds ends after its source.
      #
      # Each sample's value depends only on how many samples have passed
      # since the source's last loud sample, so the gate (and where it ends)
      # is the same at any buffer size.
      #
      # Made by GraphNode#sounding.  Use it to stop things that should run
      # only while there is sound, like a tape's hiss (bin/synths/ambient.rb
      # #ambient_tape) or a noise floor under a recording.
      class Sounding
        include GraphNode
        include SampleRateHelper

        # The source node.
        attr_reader :source

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

          @source = source.get_sampler
          @sample_rate = @source.sample_rate.to_f
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

          data = @ended ? nil : @source.sample(count)
          n = data.nil? ? 0 : data.length
          if n < count
            # The source ended (nil or a short last read): the gate plays on
            # as if it were silent, ending once closed (one short read)
            @ended = true
            if n == 0 && @quiet >= @hold + @fade
              @done = true
              return nil
            end
          end

          loud = n > 0 ? (data.abs > MB::Sound::RingOut::THRESHOLD).where : nil
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
          { input: @source }
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
