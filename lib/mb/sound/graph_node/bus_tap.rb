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

        # One channel of a BusTap.
        class Channel
          extend Forwardable

          include GraphNode
          include NodeOutput

          def_delegators :@owner, :sample_rate

          # For internal use by BusTap.
          def initialize(owner, index)
            @owner = owner
            @index = index
            @serial = nil
            @pos = 0
            @buf = nil
            @node_type_name = owner.label(index)
          end

          # The next +count+ samples of this channel of the source, in step
          # with the read the Session is rendering (see
          # Session::Buses#bus_read_serial).
          def sample(count)
            return nil if count == 0

            session = @owner.session
            @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
            if session.nil?
              return BufferHelper.zero(@buf)
            end

            serial = session.bus_read_serial
            if @serial != serial
              @serial = serial
              @pos = session.bus_read_offset
            end

            data = session.bus_signal(@owner.source_name, @owner.only)
            d = data && data[@index % data.length]
            if d.nil? || @pos >= d.length
              BufferHelper.zero(@buf)
            else
              n = MB::M.min(count, d.length - @pos)
              @buf[0...n] = d[@pos...(@pos + n)] unless FastArithmetic.copy_range(@buf, 0, d, @pos, n)
              (FastArithmetic.fill_range(@buf, n, count, 0) || (@buf[n..] = 0)) if n < count
            end
            @pos += count
            @buf
          end

          def sources
            {}.freeze
          end

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
          @outputs = Array.new(only ? 1 : channels) { |i| Channel.new(self, i) }.freeze
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
