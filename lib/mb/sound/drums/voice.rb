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
      # output within -120 dB (and with every node in its graph that has an
      # idle check idle: sampler voices, Repeats, flams, envelopes; see
      # NodeTraits; so a reversed sample's quiet start or a late burst still
      # plays), the voice stops sampling its graph (giving
      # zeros) until its next hit, like Synth's idle lanes.  Not exactly
      # the same as rendering every sample (free-running oscillators pause
      # while skipped, which only changes their phase, and filters after
      # noise keep their state; the noise itself, and other random streams,
      # catch up by the frames slept: #catch_up), but the
      # same at any buffer size: the voice falls asleep only on its own
      # grid of Synth::SKIP_GRID samples (after SLEEP_TIME rounded up to
      # whole grid cells of silence), splitting a buffer there if needed,
      # and wakes on the exact sample of the hit (2026-10-13; before, both
      # moved with the buffer edges).  Graphs with a node that blocks
      # sleeping (delays, reverbs, FIR filters without an idle check, or
      # tempo nodes: NodeTraits' blocks_sleep?) are never skipped; nodes
      # shared with other voices (e.g. a kit's
      # metal bank) are still read while skipped.
      class Voice
        include GraphNode
        # (its position, ending, and idle sleeping move to a rebuilt kit's
        # voice: #carry_adopt; its graph's nodes are their own pairs)
        node_traits memory: :short, carry: :adopt

        # How long a voice must stay below QuietRun::QUIET (-90 dB) after its
        # sources ended (for ending).
        QUIET_TIME = 0.1

        # How long a voice must stay within QuietRun::SILENCE (-120 dB)
        # before it is skipped.
        SLEEP_TIME = 0.05

        # Hands one buffer of a source the Voice read to the voice's graph.
        #
        # The source's buffer belongs to the source, which the Voice samples
        # again before its graph's next buffer, so the Tap gives the graph
        # its own copy, rewritten only when the graph samples the Tap
        # (cleanup-2: a Tee over a Tap shared a view of a Notes trigger's
        # reused buffer, which the trigger rewrote before the Tee's next
        # frame; the full-Ruby graph sweep's kit builder at 1-sample buffers
        # caught it, and a lagging branch would have read the next buffer).
        # Frozen buffers (Notes nodes' steady constants, the Voice's zeros)
        # are never rewritten and pass as they are, keeping steady-input
        # caches steady.
        class Tap
          include GraphNode
          # (the buffer its voice gives it each block)
          node_traits memory: :none

          attr_reader :sample_rate

          def initialize(name, sample_rate: 48000)
            @sample_rate = sample_rate.to_f
            @buffer = nil
            @copy = nil
            @node_type_name = name
          end

          # Set by the Voice before its graph is sampled.
          attr_writer :buffer

          def sample(count)
            b = @buffer
            raise ArgumentError, "#{@node_type_name} has #{b.length} samples, not #{count}" if b.length < count
            if b.frozen?
              return b if b.length == count
              return b[0...count]
            end

            b = b[0...count] if b.length != count
            # (the source's own type: trigger signals may be DFloat)
            @copy = b.class.zeros(count) if @copy.nil? || @copy.length != count || !@copy.instance_of?(b.class)
            @copy[0..] = b unless Kernels.copy(@copy, b)
            @copy
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
        # reads.  The first input wakes a skipped voice.  +built+ (from
        # GraphNode::Tee.collect_branches around the graph's build) tells
        # branches made while building the graph and left unread from
        # readers elsewhere (see #boundary).
        #
        # Kits are mono: a voice whose graph has several channels (a stereo
        # Sample, `h.sample(Sample['snare.flac'])` or `voice :thud,
        # Sample['wood.flac']`) plays them mixed down (Channels#mono, the
        # average), as a sampler's mono outs would (omnibus17: it raised
        # "undefined method 'get_sampler' for Channels", Kez's K5 and
        # Odile's F12).  Pan or widen the kit after it.
        def initialize(graph, name:, machine:, inputs:, notes: [], knobs: {}, skip_idle: true, sample_rate: 48000, built: nil)
          graph = graph.mono if graph.is_a?(GraphNode::Channels) || (graph.respond_to?(:channel_count) && graph.channel_count > 1)
          @graph = graph.get_sampler
          @name = name
          @bufs = []
          @machine = machine
          @inputs = inputs.map { |src, tap| [src.get_sampler, tap] }
          @notes = Array(notes).freeze
          @knobs = knobs.dup.freeze
          @sample_rate = sample_rate.to_f
          @position = 0
          # (see #check_end and #sample_skipping)
          @end_run = QuietRun.new(QUIET_TIME * @sample_rate, mode: :buffer)
          @sleep_run = QuietRun.new(Synth::SKIP_GRID, loud: QuietRun::SILENCE_LOUD, mode: :cells, grid: Synth::SKIP_GRID)
          @sleeping = false
          @out = nil
          @range = [0.0, 0.0]
          @ended = false
          @zeros = nil
          @node_type_name = "#{machine} #{name}"
          @skip_idle = !!skip_idle
          @skippable = nil
          @built = built
          @slept = 0 # (frames slept since the random streams caught up; #catch_up)
          @catch_ups = nil
        end

        def sample(count)
          return nil if @ended

          # Found at the first buffer, once every graph sharing nodes with
          # this one has been built
          setup_skipping(@skip_idle) if @skippable.nil?

          # (one reused Array of the inputs' buffers)
          bufs = @bufs
          bufs.clear
          @inputs.each { |src, tap|
            b = src.sample(count)
            b = zeros(count) if b.nil? || b.empty?
            # A source that ends inside this buffer (a one-shot clip whose
            # end is off the buffer grid) gives fewer samples; it sends no
            # more hits, so the rest is zeros while the voice rings on
            # (fixes-14: drums_808's crash at the song's end)
            b = padded(b, count) if b.length < count
            tap.buffer = b
            bufs << b
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
          @end_run.window = QUIET_TIME * @sample_rate
          self
        end

        # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true if
        # voice +old+ is the same machine's voice of the same name, skipping
        # alike.
        def carry_fits?(old)
          old.class == self.class && old.name == @name && old.machine == @machine && old.instance_variable_get(:@skip_idle) == @skip_idle
        end

        # Takes over voice +old+'s position, ending, and idle sleeping (on
        # the same grid of the voice's own time); Carry catches up the old
        # voice's random streams first (#catch_up_sleepers).
        def carry_adopt(old)
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@position @end_run @sleep_run @sleeping @ended @slept].freeze

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
        # been quiet for QUIET_TIME (whole buffers: QuietRun's :buffer mode).
        def check_end(buf)
          return buf if @notes.empty? || !@notes.all?(&:ended?)

          if @end_run.advance_buffer(buf.length, @end_run.loud?(buf))
            @ended = true
            return nil
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
          run = @sleep_run
          run.window = (SLEEP_TIME * @sample_rate / grid).ceil * grid # (whole silent cells)
          pos = @position
          whole = nil
          o = 0

          while o < count
            if @sleeping
              hit = first_hit(bufs[0], o)
              stop = hit || count
              if stop > o
                boundary.each { |n| n.sample(stop - o) }
                unless @catch_ups.empty?
                  @slept += stop - o
                  catch_up if @slept >= MB::Sound::NodeTraits::CATCH_UP_CHUNK
                end
                if o == 0 && hit.nil?
                  whole = zeros(count)
                else
                  out_buf(count)[o...stop] = 0
                end
              end
              o = stop
              next if hit.nil?

              @sleeping = false
              catch_up
              run.reset(pos + o)
            end

            # The earliest grid point where the voice could fall asleep
            # (cells not yet rendered might be silent)
            stop = run.split_point(pos, o, count)

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

            track_cells(b, pos + o)
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

        # Moves the random streams of the voice's own nodes (noise, dust,
        # drift, grains: NodeTraits' +random+ trait) on over the frames it
        # slept since they last caught up, so a voice that slept draws what
        # it would have drawn awake (see #boundary).  Session::Carry calls
        # it before copying a sleeping voice's states.
        def catch_up
          n = @slept
          return if n == 0

          @slept = 0
          MB::Sound::NodeTraits.catch_up(@catch_ups, n)
        end
        alias catch_up_sleepers catch_up
        public :catch_up_sleepers

        # The reused output buffer for buffers read in pieces.
        def out_buf(count)
          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          @out
        end

        # Moves the silent cell run (see #sample_skipping) past graph output
        # +b+ starting at voice sample +start+, falling asleep at a grid
        # point at its end that completes the run (#sample_skipping splits
        # the block there) if every idle-checked node agrees: nodes with
        # sound to come (a reversed sample's quiet start, a late burst) keep
        # the voice awake.
        def track_cells(b, start)
          run = @sleep_run
          run.track(b, start)
          @sleeping = true if run.sleep_due?(start + b.length) && MB::Sound::NodeTraits.all_idle?(@busy)
        end

        # The index of the first nonzero sample of +b+ at or after +from+, or
        # nil.
        def first_hit(b, from)
          rest = from == 0 ? b : b[from..]
          r = MB::Sound::Kernels.min_max(rest, @range)
          return nil if r ? (r[0] == 0 && r[1] == 0) : rest.abs.max == 0

          rest.ne(0).where[0] + from
        end

        def zeros(count)
          @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
          @zeros
        end

        # A new +count+-sample copy of +buf+ (shorter) padded with zeros
        # (only where a source ends, so allocating is fine).
        def padded(buf, count)
          out = buf.class.zeros(count)
          out[0...buf.length] = buf
          out
        end

        # Finds whether the graph may be skipped, and what it still reads
        # while skipped: the Tee branches it shares with other graphs (so the
        # Tees stay in step) and its Notes nodes (so their stream readers
        # do), leaving out nodes that others of these read.
        def setup_skipping(enabled)
          nodes = @graph.graph(include_tees: true)
          # (clip sources only make events: NodeTraits' timeline :events)
          skippable = !!enabled && nodes.none? { |n| MB::Sound::NodeTraits.blocks_sleep?(n) }
          unless skippable
            @busy = []
            @skippable = false
            return
          end

          @busy = MB::Sound::NodeTraits.idle_checked(nodes)

          set = nodes.to_h { |n| [n.__id__, true] }
          set[@graph.__id__] = true
          @set = set
          @tee_branches = nodes.select { |n| n.is_a?(GraphNode::Tee::Branch) }
          @notes_nodes = nodes.select { |n| n.is_a?(MB::Sound::Notes::Node) }
          @boundary_cache = nil
          @skippable = true # (last: #sample sets up again until this is set)
        end

        # Finds what skipping needs (#setup_skipping) on the thread that
        # builds the graph (Session#add), not in the render thread's first
        # buffer (alloc-2).
        def prime_render
          setup_skipping(@skip_idle) if @skippable.nil?
          nil
        end

        # What the voice reads while skipped (see #setup_skipping): its
        # branches of Tees read elsewhere (another voice, e.g. a kit's metal
        # bank, or any graph outside the voice, whose branch may be made
        # later) and its Notes nodes (e.g. a knob following a clip's notes),
        # leaving out nodes that others of these read.  Branches made while
        # building the voice's graph and read by nothing in it (e.g. an
        # unused `band * 0.5`; see GraphNode::Tee.collect_branches) don't
        # count: reading for them would run the voice's nodes while it
        # sleeps.  Decided when skipping, and cached until one of its Tees'
        # branches change (GraphNode::BranchWatch).
        def boundary
          return [] unless @skippable

          return @boundary_cache[1] if @boundary_cache && @boundary_cache[0].current?

          watch = GraphNode::BranchWatch.new(@tee_branches.map(&:owner_tee))
          set = @set
          built = @built
          shared = @tee_branches.select { |n|
            n.owner_tee.branches.any? { |b| !set[b.__id__] && !(built && built[b]) }
          }
          upstream = {}
          shared.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          shared.reject! { |n| upstream[n.__id__] }

          # Notes nodes keep their readers in step, unless a shared branch
          # above reads them
          notes_nodes = @notes_nodes.reject { |n| upstream[n.__id__] }
          notes_nodes.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          notes_nodes.reject! { |n| upstream[n.__id__] }

          list = shared + notes_nodes

          # The random streams that pause with the voice (not read through
          # the list above; see #catch_up)
          catch_up # (frames slept so far go to the nodes that slept them)
          read = {}.compare_by_identity
          list.each { |n| n.graph(include_tees: true).each { |u| read[u] = true } }
          @catch_ups = MB::Sound::NodeTraits.catching_up(@graph.graph(include_tees: true).reject { |n| read[n] })

          @boundary_cache = [watch, list]
          list
        end
      end
    end
  end
end
