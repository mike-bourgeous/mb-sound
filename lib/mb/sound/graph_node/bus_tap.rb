module MB
  module Sound
    module GraphNode
      # Reads the signal of a Session bus or player by name, for sidechains
      # and anything else in a graph (see Session::Buses and
      # design/notes/buses.md): `bus(:drums)`, `duck(:drums)`,
      # `duck(:drums, only: :kick)`, `compress(sidechain: bus(:drums))`.
      #
      # Each buffer it gives the source's samples of the same frames: the
      # Session renders the source first (players and buses render in
      # dependency order), so a duck follows the kick on the exact sample at
      # any buffer size.  Without +only+ it has one output per Session
      # channel (a bus's output, or a player's output after its fades and
      # mute, before its routing); with +only+, one output: the node named
      # +only+ inside the named track's graph (a drum voice of that name, or
      # a node given `.named(only)`), read as the track renders.
      #
      # It reads silence outside a Session, while its source isn't
      # playing, and when its source can't render before it (a cycle).
      class BusTap
        include MultiOutput
        node_traits memory: :none

        # One channel of a BusTap.
        class Channel
          extend Forwardable

          include GraphNode
          include NodeOutput
          node_traits memory: :none

          def_delegators :@owner, :sample_rate

          # Frames of the source a channel keeps past what its reads need,
          # so a graph whose reads lag a little behind the Session's (a
          # :min_phase resampler reads just what its output covers) reads
          # them in the next buffer instead of skipping them.
          KEEP = 256

          # For internal use by BusTap.
          def initialize(owner, index)
            @owner = owner
            @index = index
            @serial = nil
            @buf = nil
            @node_type_name = owner.label(index)
            @span = nil # (the routed span whose frames @hist holds last)
            @hist = nil # (the source's recent frames, from session frame @hist_start)
            @spare = nil
            @hist_start = 0
            @hist_len = 0
            @at = nil # (the session frame this channel's next read starts at)
          end

          # The next +count+ samples of this channel of the source: frames
          # BusTap#read_ahead before the graph's own (0 for most graphs: in
          # step with the read the Session is rendering, see
          # Session::Buses#bus_read_serial; a graph with a resampler after
          # the tap reads ahead, and hears the source that much later).
          # Each read in a span starts where the graph's last read ended if
          # that is near the read's own frame, else at it (a graph starting
          # or waking); frames past the span read as silence.
          def sample(count)
            return nil if count == 0

            session = @owner.session
            @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
            if session.nil?
              return BufferHelper.zero(@buf)
            end

            k = @owner.read_ahead
            span = session.bus_span
            if @span != span
              @span = span
              keep_span(session, k)
            end

            serial = session.bus_read_serial
            if @serial != serial
              @serial = serial
              o = session.bus_span_start + session.bus_read_offset
              @at = o if @at.nil? || @at < o - KEEP || @at > o + k
            end

            first = @at - k - @hist_start # (index into @hist)
            last = first + count
            lo = first < 0 ? 0 : first
            hi = last > @hist_len ? @hist_len : last
            if hi <= lo
              BufferHelper.zero(@buf)
            else
              (Kernels.fill_range(@buf, 0, lo - first, 0) || (@buf[0...(lo - first)] = 0)) if lo > first
              @buf[(lo - first)...(hi - first)] = @hist[lo...hi] unless Kernels.copy_range(@buf, lo - first, @hist, lo, hi - lo)
              (Kernels.fill_range(@buf, hi - first, count, 0) || (@buf[(hi - first)..] = 0)) if hi < last
            end
            @at += count
            @buf
          end

          def sources
            {}.freeze
          end

          # Adds this routed span's frames of the source to @hist (silence
          # if it didn't play), dropping all but the last +k+ + KEEP frames
          # before them (all of them after a gap: spans nothing read).
          def keep_span(session, k)
            start = session.bus_span_start
            frames = session.bus_span_frames || 0
            data = session.bus_signal(@owner.source_name, @owner.only)
            d = data && data[@index % data.length]

            if @hist.nil?
              @hist = Numo::SFloat.zeros(k + KEEP + 2048)
              @spare = Numo::SFloat.zeros(@hist.length)
            end
            @hist_len = 0 if @hist_start + @hist_len != start
            keep = k + KEEP
            if @hist_len > keep
              @spare[0...keep] = @hist[(@hist_len - keep)...@hist_len] unless Kernels.copy_range(@spare, 0, @hist, @hist_len - keep, keep)
              @hist, @spare = @spare, @hist
              @hist_len = keep
            end
            @hist_start = start - @hist_len

            if @hist_len + frames > @hist.length
              grown = Numo::SFloat.zeros((@hist_len + frames) * 2)
              grown[0...@hist_len] = @hist[0...@hist_len] if @hist_len > 0
              @hist = grown
              @spare = Numo::SFloat.zeros(grown.length)
            end
            len = @hist_len
            if d.nil?
              Kernels.fill_range(@hist, len, len + frames, 0) || (@hist[len...(len + frames)] = 0) if frames > 0
            else
              m = MB::M.min(frames, d.length)
              @hist[len...(len + m)] = d[0...m] if m > 0 && !Kernels.copy_range(@hist, len, d, 0, m)
              (Kernels.fill_range(@hist, len + m, len + frames, 0) || (@hist[(len + m)...(len + frames)] = 0)) if m < frames
            end
            @hist_len = len + frames
          end
          private :keep_span

          # Raises unless +rate+ is the tap's rate (it reads a Session's
          # buffers as they are).
          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end
          alias at_rate sample_rate=
        end

        # The name of the bus or player read.
        attr_reader :source_name

        # The node name read inside the source's graph (nil for the whole
        # source).
        attr_reader :only

        # The channel nodes (see Channel).
        attr_reader :outputs

        # The sample rate (the Session's, once bound).
        attr_reader :sample_rate

        # The Session read (nil until a Session plays a graph with this tap;
        # see #bind).
        attr_reader :session

        # Reads +source+ (a Symbol naming a bus or player): +channels+
        # outputs, or one output of the node named +only+.
        def initialize(source, only: nil, channels: 2, sample_rate: 48000)
          raise ArgumentError, "Bus and player names are Symbols (got #{source.inspect})" unless source.is_a?(Symbol)
          raise ArgumentError, "only: names a node in #{source.inspect}'s graph, as a Symbol (got #{only.inspect})" unless only.nil? || only.is_a?(Symbol)
          raise ArgumentError, 'channels: must be a positive Integer' unless channels.is_a?(Integer) && channels >= 1

          @source_name = source
          @only = only
          @sample_rate = sample_rate.to_f
          @session = nil
          @read_ahead = 0
          @outputs = Array.new(only ? 1 : channels) { |i| Channel.new(self, i) }.freeze
        end

        # Frames the tap gives its source late, so nodes after it that read
        # ahead of their output (a #resample) find written frames: set by
        # the Session from the graph it plays (see GraphNode::ReadAhead,
        # Session::Buses#bind_bus_taps).  0 reads the source's frames in
        # step with the Session.
        attr_reader :read_ahead

        # Sets #read_ahead (frames), before the tap is first read.
        def read_ahead=(frames)
          raise ArgumentError, "read_ahead must be a non-negative Integer (got #{frames.inspect})" unless frames.is_a?(Integer) && frames >= 0
          @read_ahead = frames
        end

        # Reads from +session+ (called by the Session for every graph it
        # plays, see Session::Buses#bind_bus_taps).
        def bind(session)
          @session = session
          self
        end

        # The display name of channel +index+.
        def label(index)
          what = @only ? "#{@source_name}[#{@only}]" : @source_name.to_s
          @only ? "bus #{what}" : "bus #{what} #{index + 1}"
        end

        def sources
          {}.freeze
        end

        # Raises unless +rate+ matches the tap's rate.
        def sample_rate=(rate)
          return self if rate.to_f == @sample_rate
          raise NotImplementedError, "A bus tap reads the Session's buffers at #{@sample_rate} Hz (asked for #{rate})" if @session
          @sample_rate = rate.to_f
          self
        end
        alias at_rate sample_rate=

        def to_s
          label(0)
        end

        # A node (one channel) or a Channels bundle for the tap's outputs,
        # as `bus(:name)` returns it.
        def node
          @outputs.length == 1 ? @outputs[0] : Channels.new(@outputs)
        end

        # The BusTap a sidechain argument names: a Symbol becomes a new tap
        # (see #initialize); anything else is returned as it is.
        def self.from(sidechain, only: nil)
          return sidechain unless sidechain.is_a?(Symbol)
          new(sidechain, only: only, channels: Session.existing&.channels || 2).node
        end
      end
    end
  end
end
