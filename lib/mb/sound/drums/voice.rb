module MB
  module Sound
    module Drums
      # One drum voice: the graph a drum machine built for it, plus what
      # plays it.  The voice reads its trigger sources itself (Notes
      # triggers or trigger signals) and hands each buffer to its graph
      # through a Tap, so it can skip the graph while idle.
      #
      # Ending: when the voice is played by a finite clip or MIDI file, it
      # ends once every source has ended and the voice has been quiet (below
      # -90 dB) for QUIET_TIME (drum envelopes are retriggerable, so they
      # never end by themselves); looping clips and live MIDI play forever.
      #
      # Idle skipping (+skip_idle: true+, the default): after SLEEP_TIME of
      # output within -120 dB, the voice stops sampling its graph (giving
      # zeros) until its next hit, like Synth's idle lanes.  Not exactly
      # the same as rendering every sample (free-running oscillators and
      # noise pause while skipped, which only changes their phase), but the
      # same at any buffer size: the voice falls asleep only on its own
      # grid of Synth::SKIP_GRID samples (after SLEEP_TIME rounded up to
      # whole grid cells of silence), splitting a buffer there if needed,
      # and wakes on the exact sample of the hit (2026-10-13; before, both
      # moved with the buffer edges).  Graphs with delays, reverbs, FIR
      # filters, or tempo nodes are never skipped (see
      # Synth.long_memory?); nodes shared with other voices (e.g. a kit's
      # metal bank) are still read while skipped.
      class Voice
        include GraphNode

        # Below this peak (-90 dB) a voice counts as quiet (for ending).
        QUIET = 10 ** (-90 / 20.0)

        # How long a voice must stay quiet after its sources ended.
        QUIET_TIME = 0.1

        # Below this peak (-120 dB) a voice counts as silent (for skipping).
        SILENCE = 1e-6

        # How long a voice must stay silent before it is skipped.
        SLEEP_TIME = 0.05

        # Hands one buffer of a source the Voice read to the voice's graph.
        class Tap
          include GraphNode

          attr_reader :sample_rate

          def initialize(name, sample_rate: 48000)
            @sample_rate = sample_rate.to_f
            @buffer = nil
            @node_type_name = name
          end

          # Set by the Voice before its graph is sampled.
          attr_writer :buffer

          def sample(count)
            b = @buffer
            return b if b.length == count

            raise ArgumentError, "#{@node_type_name} has #{b.length} samples, not #{count}" if b.length < count
            b[0...count]
          end

          def sample_rate=(rate)
            @sample_rate = rate.to_f
            self
          end

          def sources
            {}
          end
        end

        # The voice name (e.g. :kick).
        attr_reader :name

        # The drum machine's name for it (e.g. :tr808).
        attr_reader :machine

        # The graph producing the sound.
        attr_reader :graph

        # The Notes playing the voice (an Array, empty if it was given only
        # trigger signals).
        attr_reader :notes

        # The knob values used (a frozen Hash).
        attr_reader :knobs

        # Creates a voice playing +graph+.  +inputs+ is a list of [source,
        # tap] pairs: each buffer, the voice reads each source (a trigger
        # node; nil reads as zeros) and gives it to its Tap, which the graph
        # reads.  The first input wakes a skipped voice.
        def initialize(graph, name:, machine:, inputs:, notes: [], knobs: {}, skip_idle: true, sample_rate: 48000)
          @graph = graph.get_sampler
          @name = name
          @machine = machine
          @inputs = inputs.map { |src, tap| [src.get_sampler, tap] }
          @notes = Array(notes).freeze
          @knobs = knobs.dup.freeze
          @sample_rate = sample_rate.to_f
          @quiet_samples = 0
          @position = 0
          @silent_cells = 0
          @cell_loud = false
          @sleeping = false
          @out = nil
          @range = [0.0, 0.0]
          @ended = false
          @zeros = nil
          @node_type_name = "#{machine} #{name}"
          @skip_idle = !!skip_idle
          @skippable = nil
        end

        def sample(count)
          return nil if @ended

          # Found at the first buffer, once every graph sharing nodes with
          # this one has been built
          setup_skipping(@skip_idle) if @skippable.nil?

          bufs = @inputs.map { |src, tap|
            b = src.sample(count)
            b = zeros(count) if b.nil? || b.empty?
            tap.buffer = b
            b
          }

          if @skippable
            buf = sample_skipping(count, bufs)
            return nil if buf.nil?
          else
            buf = @graph.sample(count)
            if buf.nil? || buf.empty?
              @ended = true
              return nil
            end
          end

          check_end(buf)
        end

        # True while the voice skips its graph (see the class description).
        def sleeping?
          @sleeping
        end

        # True if the voice may skip its graph while idle (known after the
        # first buffer).
        def skippable?
          setup_skipping(@skip_idle) if @skippable.nil?
          @skippable
        end

        # True once the voice has ended (see the class description).
        def ended?
          @ended
        end

        attr_reader :sample_rate

        def sample_rate=(rate)
          @graph.sample_rate = rate
          @inputs.each { |src, tap| src.sample_rate = rate; tap.sample_rate = rate }
          @sample_rate = rate.to_f
          self
        end

        def sources
          s = { input: @graph }
          @inputs.each_with_index { |(src, _), i| s[:"trigger#{i == 0 ? '' : i + 1}"] = src }
          s
        end

        def to_s
          "#{@machine} #{@name} (#{@knobs.map { |k, v| "#{k}: #{v.is_a?(Numeric) ? MB::M.sigfigs(v, 3) : v}" }.join(', ')})"
        end

        private

        # Returns +buf+, or nil once the sources have ended and the voice has
        # been quiet for QUIET_TIME.
        def check_end(buf)
          return buf if @notes.empty? || !@notes.all?(&:ended?)

          if buf.abs.max < QUIET
            @quiet_samples += buf.length
            if @quiet_samples >= QUIET_TIME * @sample_rate
              @ended = true
              return nil
            end
          else
            @quiet_samples = 0
          end

          buf
        end

        # Samples the graph for +count+ samples while it may be skipped (see
        # the class description), with +bufs+ the inputs' buffers: sleeping
        # stretches give zeros, and the graph is read in pieces split where
        # the voice may fall asleep (a grid point after enough silent cells)
        # or wakes (a hit).  Returns nil if the graph ended.
        def sample_skipping(count, bufs)
          grid = MB::Sound::Synth::SKIP_GRID
          need = (SLEEP_TIME * @sample_rate / grid).ceil
          pos = @position
          whole = nil
          o = 0

          while o < count
            if @sleeping
              hit = first_hit(bufs[0], o)
              stop = hit || count
              if stop > o
                @boundary.each { |n| n.sample(stop - o) }
                if o == 0 && hit.nil?
                  whole = zeros(count)
                else
                  out_buf(count)[o...stop] = 0
                end
              end
              o = stop
              next if hit.nil?

              @sleeping = false
              @silent_cells = 0
              @cell_loud = false
            end

            # The earliest grid point where the voice could fall asleep
            # (cells not yet rendered might be silent)
            stop = count
            cells = @cell_loud ? -1 : @silent_cells
            g = ((pos + o) / grid + 1) * grid - pos
            while g <= count
              cells += 1
              if cells >= need
                stop = g
                break
              end
              g += grid
            end

            if o == 0 && stop == count
              b = @graph.sample(count)
            else
              @inputs.each_with_index { |(_, tap), i| tap.buffer = bufs[i][o...stop] }
              b = @graph.sample(stop - o)
            end
            if b.nil? || b.empty?
              @ended = true
              return nil
            end
            raise "#{@node_type_name} gave #{b.length} samples, not #{stop - o}" if b.length != stop - o

            track_cells(b, pos + o, grid, need)
            if o == 0 && stop == count
              whole = b
            else
              out_buf(count)[o...stop] = b
            end
            o = stop
          end

          @position += count
          whole || @out
        end

        # The reused output buffer for buffers read in pieces.
        def out_buf(count)
          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          @out
        end

        # Updates the silent cell count (see #sample_skipping) for graph
        # output +b+ starting at voice sample +start+, falling asleep at a
        # grid point that ends +need+ silent cells.
        def track_cells(b, start, grid, need)
          i = 0
          while i < b.length
            g = (start + i) / grid * grid + grid
            stop = [g - start, b.length].min
            @cell_loud ||= loud?(i == 0 && stop == b.length ? b : b[i...stop])
            if start + stop == g
              @silent_cells = @cell_loud ? 0 : @silent_cells + 1
              @cell_loud = false
              @sleeping = true if @silent_cells >= need
            end
            i = stop
          end
        end

        # True if +b+ has a sample beyond SILENCE.
        def loud?(b)
          r = MB::Sound::FastArithmetic.min_max(b, @range)
          r ? (r[1] > SILENCE || r[0] < -SILENCE) : b.abs.max > SILENCE
        end

        # The index of the first nonzero sample of +b+ at or after +from+, or
        # nil.
        def first_hit(b, from)
          rest = from == 0 ? b : b[from..]
          r = MB::Sound::FastArithmetic.min_max(rest, @range)
          return nil if r ? (r[0] == 0 && r[1] == 0) : rest.abs.max == 0

          rest.ne(0).where[0] + from
        end

        def zeros(count)
          @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
          @zeros
        end

        # Finds whether the graph may be skipped, and what it still reads
        # while skipped: the Tee branches it shares with other graphs (so the
        # Tees stay in step) and its Notes nodes (so their stream readers
        # do), leaving out nodes that others of these read.
        def setup_skipping(enabled)
          nodes = @graph.graph(include_tees: true)
          # Clip sources are read through Notes nodes, which stay in step
          @skippable = !!enabled && nodes.none? { |n| MB::Sound::Synth.long_memory?(n) && !n.is_a?(MB::Sound::MIDI::Source) }
          @boundary = []
          return unless @skippable

          set = nodes.to_h { |n| [n.__id__, true] }
          set[@graph.__id__] = true
          shared = nodes.select { |n|
            n.is_a?(GraphNode::Tee::Branch) && n.owner_tee.branches.any? { |b| !set[b.__id__] }
          }
          upstream = {}
          shared.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          shared.reject! { |n| upstream[n.__id__] }

          # Notes nodes (e.g. a knob following a clip's notes) keep their
          # readers in step, unless a shared branch above reads them
          notes_nodes = nodes.select { |n| n.is_a?(MB::Sound::Notes::Node) && !upstream[n.__id__] }
          notes_nodes.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          notes_nodes.reject! { |n| upstream[n.__id__] }

          @boundary = shared + notes_nodes
        end
      end
    end
  end
end
