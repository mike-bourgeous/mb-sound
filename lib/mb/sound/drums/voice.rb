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
      # zeros) until its next hit, like Synth's idle lanes.  Not
      # sample-exact: free-running oscillators (the 808's metal bank) and
      # noise pause while skipped, which only changes their phase.  Graphs
      # with delays, reverbs, FIR filters, or tempo nodes are never skipped
      # (see Synth.long_memory?); nodes shared with other voices (e.g. a
      # kit's metal bank) are still read while skipped.
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
          @silent_samples = 0
          @sleeping = false
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

          if @sleeping
            hit = bufs[0].abs.max > 0
            unless hit
              @boundary.each { |n| n.sample(count) }
              return check_end(zeros(count))
            end
            @sleeping = false
            @silent_samples = 0
          end

          buf = @graph.sample(count)
          if buf.nil? || buf.empty?
            @ended = true
            return nil
          end

          if @skippable
            peak = buf.abs.max
            if peak < SILENCE
              @silent_samples += buf.length
              @sleeping = true if @silent_samples >= SLEEP_TIME * @sample_rate
            else
              @silent_samples = 0
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

        def zeros(count)
          @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
          @zeros
        end

        # Finds whether the graph may be skipped, and the Tee branches it
        # shares with other graphs (read while skipped, so the Tees stay in
        # step), leaving out branches that other such branches read.
        def setup_skipping(enabled)
          nodes = @graph.graph(include_tees: true)
          @skippable = !!enabled && nodes.none? { |n| MB::Sound::Synth.long_memory?(n) }
          @boundary = []
          return unless @skippable

          set = nodes.to_h { |n| [n.__id__, true] }
          set[@graph.__id__] = true
          shared = nodes.select { |n|
            n.is_a?(GraphNode::Tee::Branch) && n.tee.branches.any? { |b| !set[b.__id__] }
          }
          upstream = {}
          shared.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          @boundary = shared.reject { |n| upstream[n.__id__] }
        end
      end
    end
  end
end
