module MB
  module Sound
    module Drums
      # Repeats every hit of a trigger signal (impulses valued at their
      # velocity) at fixed delays, each copy scaled by its gain: a clap's
      # bursts or a flam's second stroke.  Delays are whole samples (rounded
      # from seconds), so a hit stays one exact impulse.  Same output at any
      # buffer size: it keeps the last +longest delay+ input samples.  Ends
      # when its input ends.
      #
      #     Drums::Repeats.new(t, [[0, 1], [10.ms, 0.8], [20.ms, 0.6]])
      class Repeats
        include GraphNode
        include GraphNode::SampleRateHelper

        # The repeats as [seconds, gain] pairs.
        attr_reader :taps

        # +taps+ is a list of [delay, gain] pairs (delays in seconds or any
        # Length, 0 for the hit itself).
        def initialize(trigger, taps, sample_rate: 48000)
          raise ArgumentError, "Repeats need a trigger node (got #{trigger.inspect})" unless trigger.respond_to?(:sample)
          raise ArgumentError, 'Repeats need at least one [delay, gain] pair' if taps.empty?

          @input = trigger.get_sampler
          @taps = taps.map { |d, g|
            s = d.is_a?(Numeric) ? d : MB::Sound::Length.seconds(d)
            raise ArgumentError, "Repeat delays are 0 seconds or more (got #{d.inspect})" unless s.is_a?(Numeric) && s >= 0
            [s.to_f, g.to_f]
          }.freeze
          @sample_rate = sample_rate.to_f
          @node_type_name = 'Repeats'
          @buf = nil
          setup_delays
        end

        def sample(count)
          x = @input.sample(count)
          return nil if x.nil? || x.empty?

          n = x.length
          h = @history_length
          @work = Numo::SFloat.zeros(h + n) if @work.nil? || @work.length != h + n
          @work[0...h] = @history if h > 0
          @work[h...(h + n)] = x

          @buf = Numo::SFloat.zeros(n) if @buf.nil? || @buf.length != n
          @buf.fill(0)
          @delays.each_with_index do |d, i|
            g = @gains[i]
            seg = @work[(h - d)...(h - d + n)]
            @buf.inplace + (g == 1 ? seg : seg * g)
          end

          @history = @work[n...(n + h)].dup if h > 0
          @buf
        end

        def sample_rate=(rate)
          super
          setup_delays
          self
        end

        # True when no hit is waiting to be repeated (see Drums::Voice's
        # idle skipping).
        def idle?
          @history_length == 0 || @history.ne(0).count_true == 0
        end

        def sources
          { input: @input }
        end

        def to_s
          "Repeats (#{@taps.map { |d, g| "#{MB::M.sigfigs(d * 1000, 3)} ms x#{MB::M.sigfigs(g, 3)}" }.join(', ')})"
        end

        private

        def setup_delays
          @delays = @taps.map { |d, _| (d * @sample_rate).round }
          @gains = @taps.map(&:last)
          @history_length = @delays.max
          @history = Numo::SFloat.zeros(@history_length)
          @work = nil
        end
      end

      # A voice's choke: 1 while the voice plays, falling linearly to 0 over
      # Envelope::CHOKE_TIME (3 ms) from a hit of +choke+ (another voice of
      # its choke group), back to 1 at the voice's own next hit (+trigger+;
      # a hit and a choke on the same sample: the hit wins).  Same output at
      # any buffer size.  Ends when its trigger ends.
      class ChokeGate
        include GraphNode
        include GraphNode::SampleRateHelper

        def initialize(trigger, choke, sample_rate: 48000)
          @trigger = trigger.get_sampler
          @choke = choke.get_sampler
          @sample_rate = sample_rate.to_f
          @node_type_name = 'Choke'
          @level = 1.0  # level before the ramp (or the steady level)
          @ramp = nil   # samples into the ramp, or nil
          @buf = nil
          setup_ramp
        end

        def sample(count)
          t = @trigger.sample(count)
          return nil if t.nil? || t.empty?
          c = @choke.sample(count)
          n = t.length
          c = nil if c.nil? || c.empty?
          n = MB::M.min(n, c.length) if c

          hits = event_indices(t, n)
          chokes = c ? event_indices(c, n) : []

          @buf = Numo::SFloat.zeros(n) if @buf.nil? || @buf.length != n
          events = (hits.map { |i| [i, 0] } + chokes.map { |i| [i, 1] }).sort
          o = 0
          events.each_with_index do |(i, kind), idx|
            # A hit and a choke on the same sample: the hit wins
            next if kind == 1 && events[idx + 1]&.first == i
            next if kind == 1 && idx > 0 && events[idx - 1] == [i, 0]
            fill(o, i)
            o = i
            if kind == 0
              @level = 1.0
              @ramp = nil
            else
              @level = current
              @ramp = 0
            end
          end
          fill(o, n)
          @buf
        end

        def sample_rate=(rate)
          super
          setup_ramp
          self
        end

        def sources
          { trigger: @trigger, choke: @choke }
        end

        private

        def setup_ramp
          @ramp_length = MB::M.max(1, (MB::Sound::Envelope::CHOKE_TIME * @sample_rate).round)
        end

        # The level at the current sample (before filling it).
        def current
          return @level if @ramp.nil?
          @ramp >= @ramp_length ? 0.0 : @level * (1.0 - @ramp.to_f / @ramp_length)
        end

        # Fills @buf[from...to] from the current state, advancing it.
        def fill(from, to)
          len = to - from
          return if len <= 0

          if @ramp.nil?
            @buf[from...to] = @level
          elsif @ramp >= @ramp_length
            @buf[from...to] = 0
          else
            k = Numo::DFloat.new(len).seq(@ramp)
            v = (1.0 - k / @ramp_length).clip(0, 1) * @level
            @buf[from...to] = v
            @ramp += len
          end
        end

        def event_indices(x, n)
          x = x[0...n] if x.length != n
          return [] if x.ne(0).count_true == 0
          x.ne(0).where.to_a
        end
      end
    end
  end
end

module MB
  module Sound
    module Drums
      # Plays flam-marked hits as flams: at each hit of +trigger+ where
      # +mark+ (Notes#flam_mark) isn't 0, a grace stroke (GRACE of the
      # hit's velocity) on the hit's sample, then the hit +mark+ seconds
      # later (+spacing+ seconds for a mark of Notes::FlamMark::DEFAULT,
      # i.e. `C1.flam` without a time); other hits pass through.  Delays
      # are whole samples; the same output at any buffer size.  Ends when
      # its trigger ends.
      class Flams
        include GraphNode
        include GraphNode::SampleRateHelper

        # The grace stroke's share of the hit's velocity.
        GRACE = 0.6

        # The spacing (seconds) for marks without their own.
        attr_reader :spacing

        def initialize(trigger, mark, spacing:, sample_rate: 48000)
          @trigger = trigger.get_sampler
          @mark = mark.get_sampler
          @spacing = MB::Sound::Length.seconds(spacing).to_f
          raise ArgumentError, "A flam spacing is over 0 seconds (got #{spacing.inspect})" unless @spacing > 0
          @sample_rate = sample_rate.to_f
          @node_type_name = 'Flams'
          @pending = [] # [samples from now, velocity]
          @bufs = nil
        end

        def sample(count)
          t = @trigger.sample(count)
          return nil if t.nil? || t.empty?
          m = @mark.sample(count)
          n = t.length
          n = MB::M.min(n, m.length) if m && !m.empty?

          # Two output buffers in turn: a Voice hands this buffer to its
          # graph through a Tap whose Tee branches share it until the next
          # buffer is read
          @bufs = [Numo::SFloat.zeros(n), Numo::SFloat.zeros(n)] if @bufs.nil? || @bufs[0].length != n
          @bufs.reverse!
          @buf = @bufs[0]
          @buf[0...n] = n == t.length ? t : t[0...n]

          hits = t[0...n].ne(0)
          if m && !m.empty? && hits.count_true > 0
            hits.where.each do |i|
              f = m[i]
              next if f == 0
              v = @buf[i]
              @buf[i] = v * GRACE
              d = ((f < 0 ? @spacing : f) * @sample_rate).round
              @pending << [i + MB::M.max(d, 1), v]
            end
          end

          unless @pending.empty?
            later = []
            @pending.each do |pos, v|
              if pos < n
                @buf[pos] = @buf[pos] + v
              else
                later << [pos - n, v]
              end
            end
            @pending = later
          end

          @buf
        end

        # True when no second stroke is waiting.
        def idle?
          @pending.empty?
        end

        def sources
          { trigger: @trigger, mark: @mark }
        end

        def to_s
          "Flams (#{MB::M.sigfigs(@spacing * 1000, 3)} ms)"
        end
      end
    end
  end
end
