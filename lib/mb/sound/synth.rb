module MB
  module Sound
    # A polyphonic synth built from a MIDI source: a MIDI::Allocator splits
    # the source's notes among voice lanes, the block builds one graph per
    # lane from a Notes instance (+v+) on that lane, and the synth sums the
    # lane graphs.  Clip#synth and MB::Sound.synth build one.
    #
    #     s = MB::Sound::Synth.new(seq(C3, E3, G3, B3).n8.loop, voices: 4) { |v|
    #       v.hz.saw.filter(:lowpass, cutoff: v.cutoff(600), quality: v.quality(2)) * v.amp_env(0.01, 0.2, 0.6, 0.3)
    #     }
    #     play s
    #
    # Source: anything MIDI::Stream.for accepts (a Clip, a MIDI filename, a
    # MIDIFile, a MIDI::Source such as a LiveSource, or a Stream).  The
    # synth reads it through the sustain pedal transform (MIDI::Stream#sustain;
    # +sustain: false+ skips it) and, with +:bend_range+ (an Interval or
    # semitones, e.g. `12.st`), a default pitch bend range (RPN 0 still
    # overrides it; 2 semitones otherwise).
    #
    # Voices: +:voices+, +:spares+, +:steal+, +:protect+, +:mono+,
    # +:priority+, and +:glide_mode+ go to MIDI::Allocator (see there for
    # stealing with chokes, spare lanes, mono mode, and glide modes).  The
    # block is called once per lane (voices + spares lanes, or one in mono
    # mode) with the lane's Notes and the lane index.  Each lane's Notes
    # tells the allocator when a released lane has gone quiet (Notes#idle?:
    # no held note, every envelope made through +v+ idle, and the lane's
    # output quiet; see #quiet_lanes), and its level (Notes#level) for the
    # :quietest steal policy.
    #
    # Same-note retriggers (+:retrigger+, one word): :reuse (the default),
    # :louder, and :new_voice go to MIDI::Allocator (see there); with
    # :louder a lane counts as louder when the new note's velocity would
    # take each envelope made through +v+ at least as high as it is now
    # (Envelope#retrigger_peak >= Envelope#level: no envelope would attack
    # downward).  :add reuses lanes like :reuse and sets every envelope
    # made through +v+ to Envelope's +retrigger: :add+ (a re-strike attacks
    # to the energy sum of the current level and its own peak).  Lanes
    # re-struck while their :add envelopes still sound keep the phases of
    # key-synced oscillators (Notes#key_trigger leaves those note-ons out),
    # so a re-strike adds energy without a click; a lane whose envelopes
    # have ended resets as a new note.  With :reuse (:restart envelopes)
    # re-strikes reset key-synced oscillators, as before.
    #
    # Presets for ringing sounds (RETRIGGER_PRESETS):
    # - :string (piano, e-piano, plucked or struck strings): one lane per
    #   key, re-struck in place even with voices free (Allocator
    #   +retrigger: :per_key+), its envelopes adding the strike's energy
    #   (Envelope +retrigger: :add+), so a repeated key never doubles.
    #   A re-struck string keeps its phase, and so do key-synced
    #   oscillators here (see :add); `.free` ones never reset.
    # - :ring (alias :bell; bells and other ringing sounds): a same-note
    #   strike takes a free voice if one is free (as always); with every
    #   voice busy it reuses the quietest lane already playing that note,
    #   its envelopes adding the new strike's energy (Envelope
    #   +retrigger: :add+); with no lane playing the note it steals the
    #   quietest lane (a choke, as usual).  That is Allocator
    #   +retrigger: :quietest+, +steal: RING_STEAL+ (unless +:steal+ is
    #   given), and :add envelopes.
    #
    #     midi.synth(voices: 4, retrigger: :ring) { |v| ... }
    #     midi.synth(voices: 8, retrigger: :string) { |v| v.hz.sine.free * v.amp_env(0.002, 2, 0, 0.3) }
    #
    # With :add envelopes (:add, :string, :ring) a lane never rises above
    # sqrt(2) times one strike's peak however fast it is struck (see
    # Envelope's +retrigger: :add+); :ring can still stack up to +voices+
    # lanes of one note, since a strike takes a free voice first.
    #
    # Randomness: each lane's block runs with the root random generator
    # restarted from +seed+ + lane index (MB::Sound.with_seed), so lane
    # tones that call #rnd get different, repeatable phases.  +:seed+
    # defaults to a seed drawn from the root generator (MB::Sound.next_seed),
    # so synths made in the same order after the same MB::Sound.seed repeat.
    #
    # Channels: lane graphs may return several channels (a Channels bundle
    # or an Array of nodes); the synth then has as many output channels as
    # the widest lane, with narrower lanes repeated across channels, and
    # its #outputs are one node per channel (Clip#synth returns them as a
    # Channels bundle).  Lanes can be
    # spread across the stereo field in the block, e.g.
    # `{ |v, i| (v.hz.saw * v.amp_env).pan(i.odd? ? -0.5 : 0.5) }`, or
    # read separately with #sample_individual.
    #
    # Output controls (+:controls+, all off by default): :volume (CC 7,
    # starting at 100) and :expression (CC 11, starting at 127) scale the
    # mix by the GM curve of 40·log10(value / 127) dB each, i.e. (value /
    # 127)²; :pan (CC 10, center 64) pans a mono synth to stereo (or
    # balances a stereo one; ChannelMixer::Pan, equal power).
    #
    # Ending: #ended? is true once a finite source (a MIDI file or a
    # non-looping clip) has ended, every lane has read its last event, and
    # every lane is idle (including quiet; see #quiet_lanes, so voices
    # without envelopes ring out); the script runner's ringdown then stops a synth
    # script after a second of quiet, so effects after the synth (delays,
    # reverbs) ring out.  A lane graph that returns nil (its Notes gate or
    # trigger ends once the source has ended and the lane is idle) drops
    # out of the mix.  Once every lane has, the synth outputs silence for
    # +:tail+ seconds (TAIL_SECONDS by default, like the old MIDI file
    # nodes, for players that don't check #ended?; any length, e.g.
    # `2.bars`; 0 to end at once), then #sample returns nil.
    class Synth
      include GraphNode
      include GraphNode::SampleRateHelper

      # Output controls (see the class description).
      CONTROLS = [:volume, :expression, :pan].freeze

      # Same-note retrigger modes (see the class description).
      # Named retrigger presets for ringing sounds, each with its canonical
      # name (see the class description).
      RETRIGGER_PRESETS = { string: :string, ring: :ring, bell: :ring }.freeze

      RETRIGGER_MODES = [*MIDI::Allocator::RETRIGGER_MODES, :add, *RETRIGGER_PRESETS.keys].freeze

      # The steal chain of +retrigger: :ring+ (see the class description).
      RING_STEAL = [:same_note, :quietest, :oldest].freeze

      # Allocator retrigger modes for the Synth-only modes.
      ALLOCATOR_RETRIGGER = { add: :reuse, ring: :quietest, string: :per_key }.freeze

      # The default +:tail+: seconds of silence after every lane has ended
      # before #sample returns nil (the old MIDI file nodes' limit).
      TAIL_SECONDS = MIDI::MIDIFile::TAIL_SECONDS

      # One output channel of a multichannel synth (see Synth#outputs).
      class Output
        include GraphNode
        include GraphNode::SampleRateHelper

        # The channel index.
        attr_reader :index

        def initialize(synth, index)
          @synth = synth
          @index = index
          @node_type_name = "Synth output #{index + 1}"
        end

        def sample(count)
          @synth.sample_channel(count, @index)
        end

        def sample_rate
          @synth.sample_rate
        end

        # Changes the sample rate of the whole synth.
        def sample_rate=(rate)
          @synth.sample_rate = rate
          self
        end

        def sources
          { synth: @synth }
        end

        def to_s
          "#{@synth} output #{@index + 1} of #{@synth.channel_count}"
        end
      end

      # The MIDI::Allocator splitting the source among lanes.
      attr_reader :allocator

      # The plan installation of each lane (see MB::Sound::Plan; nil for a
      # lane without fused regions or with plans off).
      attr_reader :plans

      # The Notes instance of each lane (in lane order).
      attr_reader :notes

      # The seed of lane 0 (lane i uses seed + i; see the class
      # description).
      attr_reader :seed

      # The output controls in use (see CONTROLS; the +:controls+ given to
      # the constructor).
      attr_reader :output_controls

      # The same-note retrigger mode (see the class description).
      attr_reader :retrigger

      # See the class description.
      def initialize(
        source, voices: 8, spares: 2, steal: nil, protect: nil, mono: nil,
        priority: :last, glide_mode: :last, retrigger: :reuse, controls: [], bend_range: nil, sustain: true,
        seed: nil, tail: TAIL_SECONDS, skip_idle: true, sample_rate: 48000, &block
      )
        raise ArgumentError, 'Pass a block that builds the graph of one voice from |v, index|' unless block

        unless RETRIGGER_MODES.include?(retrigger)
          raise ArgumentError, "Unknown retrigger mode #{retrigger.inspect} (use #{RETRIGGER_MODES})"
        end
        @retrigger = retrigger
        retrigger = RETRIGGER_PRESETS.fetch(retrigger, retrigger)
        steal ||= retrigger == :ring ? RING_STEAL : MIDI::Allocator::DEFAULT_STEAL
        add = retrigger == :add || retrigger == :ring || retrigger == :string

        @output_controls = Array(controls).uniq.freeze
        bad = @output_controls - CONTROLS
        raise ArgumentError, "Unknown synth controls #{bad} (use #{CONTROLS})" unless bad.empty?

        @sample_rate = sample_rate.to_f
        @tail = Length.seconds(tail).to_f
        @tail_samples = 0
        @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)

        stream = MIDI::Stream.for(source)
        stream = stream.bend_range(bend_range) if bend_range
        stream = stream.sustain if sustain
        @sustain = !!sustain

        @allocator = MIDI::Allocator.new(
          stream, voices: voices, spares: spares, steal: steal, protect: protect, mono: mono,
          priority: priority, glide_mode: glide_mode, retrigger: ALLOCATOR_RETRIGGER.fetch(retrigger, retrigger)
        )

        @notes = []
        @quiet = Array.new(@allocator.lanes.length, true)
        @silent = Array.new(@allocator.lanes.length, true)
        @peaks = Array.new(@allocator.lanes.length, 0.0)
        @lanes = @allocator.lanes.each_with_index.map { |lane, idx|
          v = Notes.new(lane, sustain: false, sample_rate: @sample_rate)
          v.quiet_check = -> { @quiet[idx] }
          v.level_check = -> { @peaks[idx] }
          graph = MB::Sound.with_seed(@seed + idx) { block.call(v, idx) }
          lane.idle_check = -> { v.idle? }
          lane.level_check = -> { v.level }
          lane.louder_check = ->(velocity) { louder_lane?(v, velocity) }
          v.envelopes.each { |env| env.retrigger(:add) if env.respond_to?(:retrigger) } if add
          @notes << v
          lane_outputs(graph, idx).map(&:get_sampler)
        }
        @notes.freeze

        # Fused plans for each lane's graph (see MB::Sound::Plan)
        @plans = @lanes.map { |outs| Plan.install(outs) }

        @channels = @lanes.map(&:length).max
        @done = Array.new(@lanes.length, false)
        setup_idle_skipping(skip_idle)
        @buf = nil
        @channel_bufs = nil
        @sampled = []
        @frame = nil

        @control_notes = Notes.new(@allocator.stream, sustain: false, sample_rate: @sample_rate) unless @output_controls.empty?
        @gain = make_gain
        @core_outputs = @channels > 1 || @output_controls.include?(:pan) ? Array.new(@channels) { |c| Output.new(self, c) } : nil
        @final = make_pan

        @node_type_name = "Synth (#{@allocator.mono? ? 'mono' : "#{voices} voices"})"
      end

      # A MIDI::ControlMap of the controllers this synth responds to: the
      # controller nodes of its lanes (shared by every lane), its output
      # controls, and the sustain pedals unless +sustain: false+ (see
      # #control_specs).  Prints as a listing in the console;
      # `synth.controls.to_acid_xml` gives an ACID controller map.
      def controls
        MIDI::ControlMap.new(self)
      end

      # The MIDI::ControlSpecs behind #controls.
      def control_specs
        # Every lane (and the output controls' Notes) shares one control
        # stream, the allocator's input
        specs = Notes.new(@allocator.stream, sustain: false).control_specs
        @sustain ? specs + MIDI::Transform::Sustain::CONTROL_SPECS : specs
      end

      # The number of voices (active lanes) the allocator allows.
      def voices
        @allocator.voices
      end

      # The allocator's voice lanes (MIDI::Allocator::Lane streams).
      def lanes
        @allocator.lanes
      end

      # The number of spare lanes in use (see MIDI::Allocator#spares=).
      def spares
        @allocator.spares
      end

      # Changes the number of spare lanes in use, from 0 up to the +:spares+
      # given to the constructor (see MIDI::Allocator#spares=).
      def spares=(count)
        @allocator.spares = count
      end

      # True in mono mode (see MIDI::Allocator).
      def mono?
        @allocator.mono?
      end

      # The output nodes: the synth itself when it has one channel and no
      # pan control, else one node per channel (see the class description).
      def outputs
        @final ? @final.outputs : (@core_outputs || [self])
      end

      # Returns +count+ samples of the mix (a reused buffer), or nil once
      # every lane has ended (see the class description).  Only for a synth
      # with one channel and no pan control; sample #outputs otherwise.
      def sample(count)
        if @core_outputs
          raise ArgumentError, "#{self} has #{channel_count} output channels; sample its #outputs (or play it)"
        end

        mix_mono(count)
      end

      # Samples every lane once, returning one buffer per lane (lanes with
      # one channel), or an Array of channel buffers per lane, before the
      # output controls; nil for lanes that have ended, or nil once every
      # lane has ended.  Takes the place of #sample for that buffer (e.g.
      # to place voices yourself); don't mix the two.  Lanes skipped while
      # idle (see #skip_idle?) give frozen buffers of zeros.
      def sample_individual(count)
        data = sample_lanes(count)
        data&.map { |d| d.is_a?(Array) ? d.dup : d }
      end

      # True if lanes may be skipped while idle (the +:skip_idle+ option;
      # see #skippable_lanes).
      def skip_idle?
        @skip_idle
      end

      # The indices of lanes that may be skipped while idle: with
      # +:skip_idle+ on (the default), lanes whose graphs have no delays,
      # reverbs, FIR filters, or tempo-following nodes (see
      # #setup_idle_skipping).
      def skippable_lanes
        @skippable.each_index.select { |idx| @skippable[idx] }
      end

      # The indices of the lanes being skipped right now.
      def skipped_lanes
        @skipping.each_index.select { |idx| @skipping[idx] }
      end

      # The indices of the lanes whose last rendered buffer was quiet (every
      # channel within -90 dB, QUIET) with no note held and every envelope idle
      # (or that haven't rendered since).  A lane counts as busy for the
      # allocator (and its Notes gate and trigger keep going after a MIDI
      # file ends) until it is quiet, so voices without envelopes, such as
      # resonant filter pings, ring out.  Measured once per buffer, after
      # the lane renders, so allocation stays the same for the same events
      # and buffer sizes.
      def quiet_lanes
        @quiet.each_index.select { |idx| @quiet[idx] }
      end

      # True once the source has ended, every lane has read its last event,
      # and every lane is idle (see the class description).
      def ended?
        @allocator.lanes.all?(&:ended?) && @notes.all?(&:idle?)
      end

      # Used by Output#sample: computes a frame of every channel the first
      # time any channel is sampled, or when a channel is sampled again
      # (like ChannelMixer), and returns channel +index+.
      def sample_channel(count, index)
        return mix_mono(count) if @channels == 1

        if @frame.nil? || @sampled.include?(index)
          if !@sampled.empty? && @sampled.length != @channels
            warn "#{self} output #{index + 1} sampled again before other outputs"
          end
          @sampled.clear
          @frame = mix_channels(count)
        end

        return nil if @frame == :ended

        @sampled << index
        @frame[index]
      end

      def sources
        list = {}
        @lanes.each_with_index do |outs, idx|
          outs.each_with_index do |o, c|
            list[outs.length == 1 ? :"voice_#{idx + 1}" : :"voice_#{idx + 1}_#{c + 1}"] = o
          end
        end
        list[:gain] = @gain if @gain
        list
      end

      def to_s
        node_type_name
      end

      private

      # True if a note at +velocity+ would take each envelope of lane Notes
      # +v+ at least as high as it is now (see +retrigger: :louder+).
      def louder_lane?(v, velocity)
        v.envelopes.all? { |env|
          !env.respond_to?(:retrigger_peak) || env.retrigger_peak(velocity) >= env.level.to_f.abs
        }
      end

      # Level below which a released lane counts as quiet, so it can be
      # reused and a finished source can end (-90 dB, like the master
      # effects tails of Session; see #quiet_lanes).
      QUIET = -90.db

      # Level below which a lane's output counts as silent for idle lane
      # skipping (-120 dB; stricter than QUIET because skipping changes the
      # output; see #setup_idle_skipping).
      SILENCE = 1e-6

      # Node classes whose state can hold sound that comes back after a
      # silent stretch (delays, reverbs, long FIR filters) or that follow
      # the timeline (tempo LFOs), so lanes using them are never skipped.
      def self.long_memory?(node)
        node.is_a?(GraphNode::Reverb) || node.is_a?(GraphNode::FdnReverb) || node.is_a?(GraphNode::MultitapDelay) ||
          node.is_a?(Sequence::TimelineNode) ||
          (node.respond_to?(:base_filter) && (node.base_filter.is_a?(Filter::Delay) || node.base_filter.is_a?(Filter::FIR))) ||
          node.is_a?(Filter::Delay) || node.is_a?(Filter::FIR)
      end

      # Idle lane skipping (+:skip_idle+, on by default).  A lane is skipped
      # (its graph isn't sampled, and it outputs zeros) from the buffer
      # after one in which
      # - its Notes is idle (Notes#idle?: no held note, every envelope made
      #   through it idle), and
      # - every output channel of the lane stayed within -120 dB (SILENCE),
      # and its graph has no long-memory nodes (see .long_memory?).  While
      # skipped, the lane's own Notes nodes and its branches of nodes shared
      # with other lanes (controllers, bend) are still read every buffer, so
      # their readers and Tees stay in step; the lane wakes (renders again)
      # at the first buffer with an event for it (note, controller, choke,
      # glide) or after a content jump.
      #
      # Differences from rendering every lane (why it isn't sample-exact):
      # free-running oscillators and LFOs in a skipped lane pause instead of
      # advancing, key-synced oscillators reset from where they paused (the
      # band-limited reset step starts from a different value), and filter
      # states keep the residue they had below -120 dB.  Pass +skip_idle:
      # false+ for exact rendering.
      def setup_idle_skipping(enabled)
        @skip_idle = !!enabled
        @skipping = Array.new(@lanes.length, false)
        @skip_generation = Array.new(@lanes.length)
        @zeros = nil

        graphs = @lanes.map { |outs| outs.flat_map { |o| o.graph(include_tees: true) }.uniq }
        sets = graphs.map { |g| g.to_h { |n| [n.__id__, true] } }

        @skippable = graphs.each_with_index.map { |g, idx|
          @skip_idle && g.none? { |n| Synth.long_memory?(n) } && g.any? { |n| n.is_a?(Notes::Node) && n.notes.equal?(@notes[idx]) }
        }

        # What a skipped lane still reads: its own Notes nodes, and its
        # branches of Tees whose other branches are in other lanes
        @boundary = graphs.each_with_index.map { |g, idx|
          next [] unless @skippable[idx]

          # Nodes read by other boundary nodes (e.g. a Glide's time input)
          # are read through them
          own = g.select { |n| n.is_a?(Notes::Node) && n.notes.equal?(@notes[idx]) }
          upstream = {}
          own.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          own.reject! { |n| upstream[n.__id__] }

          shared = g.select { |n|
            n.is_a?(GraphNode::Tee::Branch) && !upstream[n.__id__] && n.tee.branches.any? { |b| !sets[idx][b.__id__] }
          }
          own + shared
        }
        @clock_node = @boundary.map { |b| b.find { |n| n.is_a?(Notes::Node) } }
      end

      # True if lane +idx+ should be skipped from the next buffer (see
      # #setup_idle_skipping): its Notes is idle and the buffer just
      # rendered was silent (within SILENCE).
      def start_skipping?(idx)
        return false unless @silent[idx]

        @skip_generation[idx] = @allocator.lanes[idx].generation
        true
      end

      # Records the level of lane +idx+'s channel buffers +bufs+ (for
      # Notes#level), and whether the lane is quiet (QUIET; see
      # #quiet_lanes) and silent (SILENCE; see #start_skipping?).  Quiet
      # and the level use half the peak-to-peak range, ignoring a constant
      # offset (e.g. a waveshaper's output for silence, which would keep a
      # lane busy forever); silent uses the absolute peak, since skipping
      # replaces the lane's output with zeros.
      def measure_lane(idx, bufs)
        lo = hi = swing = nil
        bufs.each do |b|
          mn, mx = range_of(b)
          lo = mn if lo.nil? || mn < lo
          hi = mx if hi.nil? || mx > hi
          sw = (mx - mn) * 0.5
          swing = sw if swing.nil? || sw > swing
        end
        idle = @notes[idx].voice_idle?
        @peaks[idx] = swing
        @quiet[idx] = idle && swing <= QUIET
        @silent[idx] = idle && hi <= SILENCE && lo >= -SILENCE
      end

      # Marks lane +idx+ as ended (silent from now on).
      def lane_ended(idx)
        @done[idx] = @quiet[idx] = @silent[idx] = true
        @peaks[idx] = 0.0
      end

      # The smallest and largest samples of +buf+ (magnitudes if complex),
      # in an Array reused by every call (FastArithmetic.min_max for real
      # buffers, so nothing is allocated).
      def range_of(buf)
        r = (@range ||= [0.0, 0.0])
        if buf.equal?(@zeros)
          r[0] = r[1] = 0.0
          return r
        end

        return r if MB::Sound::FastArithmetic.min_max(buf, r)

        buf = buf.abs if buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex)
        r[0] = buf.min.to_f
        r[1] = buf.max.to_f
        r
      end

      # Skips lane +idx+ for +count+ samples, reading its boundary nodes
      # (see #setup_idle_skipping): returns :skipped, :ended if one of them
      # ended, or :wake (rendering resumes with this buffer) if the lane
      # has an event in this buffer or its content jumped.
      def skip_lane(idx, count)
        lane = @allocator.lanes[idx]
        clock = @clock_node[idx]
        if lane.generation != @skip_generation[idx] || lane.pending_before?(clock.next_cursor(count))
          @skipping[idx] = false
          return :wake
        end

        @boundary[idx].each do |n|
          # Notes nodes advance without a buffer (also inside fused plans)
          return :ended if (n.is_a?(Notes::Node) ? n.advance(count) : n.sample(count)).nil?
        end

        :skipped
      end

      # A frozen buffer of +count+ zeros for skipped lanes.
      def zeros(count)
        @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
        @zeros
      end

      # The output nodes of one lane's graph.
      def lane_outputs(graph, idx)
        outs = case graph
               when Array then graph.flat_map { |g| g.respond_to?(:outputs) ? g.outputs : [g] }
               else graph.respond_to?(:outputs) ? graph.outputs : [graph]
               end

        unless !outs.empty? && outs.all? { |o| o.respond_to?(:sample) }
          raise ArgumentError, "The synth block must return a graph node or channels for lane #{idx} (got #{graph.inspect})"
        end

        outs
      end

      # The gain node of the volume and expression controls (their product;
      # squared by #apply_gain), or nil.
      def make_gain
        parts = []
        parts << @control_notes.volume if @output_controls.include?(:volume)
        parts << @control_notes.expression if @output_controls.include?(:expression)
        return nil if parts.empty?

        node = parts.length == 1 ? parts[0] : GraphNode::Multiplier.new(parts, sample_rate: @sample_rate)
        node.get_sampler
      end

      # The pan stage (a mono synth panned, or a stereo synth balanced), or
      # nil.
      def make_pan
        return nil unless @output_controls.include?(:pan)

        if @channels > 2
          raise ArgumentError, "The pan control needs a mono or stereo synth (lanes have #{@channels} channels)"
        end

        input = @channels == 1 ? @core_outputs[0] : GraphNode::Channels.new(@core_outputs)
        result = input.pan(@control_notes.pan)
        result.is_a?(GraphNode::Channels) ? result : GraphNode::Channels.new(result.outputs)
      end

      # #sample_individual's work, in Arrays reused by every call (the
      # result, and each lane's Array of channel buffers), for #mix_mono and
      # #mix_channels.
      def sample_lanes(count)
        any = false
        data = (@lane_data ||= Array.new(@lanes.length))
        idx = 0
        while idx < @lanes.length
          data[idx] = sample_lane(idx, count)
          any = true unless data[idx].nil?
          idx += 1
        end

        any ? data : nil
      end

      # One lane's entry of #sample_lanes.
      def sample_lane(idx, count)
        return nil if @done[idx]

        outs = @lanes[idx]
        if @skipping[idx]
          case skip_lane(idx, count)
          when :ended
            lane_ended(idx)
            return nil
          when :skipped
            return outs.length == 1 && @channels == 1 ? zeros(count) : Array.new(outs.length) { zeros(count) }
          end
        end

        bufs = ((@lane_bufs ||= [])[idx] ||= [])
        bufs.clear
        outs.each do |o|
          buf = o.sample(count)
          if buf.nil?
            lane_ended(idx)
            return nil
          end
          bufs << buf
        end

        measure_lane(idx, bufs)
        @skipping[idx] = start_skipping?(idx) if @skippable[idx]

        outs.length == 1 && @channels == 1 ? bufs[0] : bufs
      end

      # Sums the lanes into one buffer, with the output gain.
      def mix_mono(count)
        data = sample_lanes(count)
        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
        return (tail_silence(count) ? @buf.fill(0) : nil) if data.nil?

        out = sum_into(@buf, data)
        apply_gain(out, count)
      end

      # Sums each channel of the lanes (narrower lanes repeat across
      # channels), with the output gain.  Returns :ended once every lane has
      # ended.
      def mix_channels(count)
        data = sample_lanes(count)
        @channel_bufs = Array.new(@channels) { Numo::SFloat.zeros(count) } if @channel_bufs.nil? || @channel_bufs[0].length != count
        if data.nil?
          return :ended unless tail_silence(count)
          return @channel_bufs.map { |b| b.fill(0) }
        end

        gain = gain_data(count)
        return :ended if @gain && gain.nil?

        Array.new(@channels) { |c|
          out = sum_into(@channel_bufs[c], data, c)
          @channel_bufs[c] = out if out.length == count && !out.equal?(@channel_bufs[c]) # a promoted (e.g. complex) buffer
          gain ? scale(out, gain) : out
        }
      end

      # Counts +count+ samples of silence after every lane has ended.
      # Returns false once the +:tail+ is over (see the class description).
      def tail_silence(count)
        return false if @tail_samples >= @tail * @sample_rate
        @tail_samples += count
        true
      end

      # Adds the lane buffers of +data+ (from #sample_lanes; nil for ended
      # lanes, or with a +channel+, each lane's Array of channel buffers,
      # narrower lanes repeating) into +out+ (zeroed first).  Shorter
      # buffers add to the start.  Returns +out+, or a new buffer if a lane
      # promoted the type (e.g. complex).  Full buffers of out's type take
      # MB::Sound::FastArithmetic.mix (the same additions, no allocations).
      def sum_into(out, data, channel = nil)
        pairs = (@sum_pairs ||= [])
        pool = (@sum_pool ||= [])
        n = 0
        fast = true
        data.each do |d|
          next if d.nil?
          d = d[channel % d.length] if channel
          next if d.equal?(@zeros) # a skipped lane
          unless d.class == out.class && d.length == out.length
            fast = false
            break
          end
          pair = (pool[n] ||= [nil, 1])
          pair[0] = d
          pairs[n] = pair
          n += 1
        end
        if fast
          pairs.pop while pairs.length > n
          return out if MB::Sound::FastArithmetic.mix(out, 0, pairs)
        end

        out.fill(0)
        data.each do |d|
          next if d.nil?
          d = d[channel % d.length] if channel
          next if d.equal?(@zeros) # a skipped lane
          n = MB::M.min(d.length, out.length)
          if (d.is_a?(Numo::SComplex) || d.is_a?(Numo::DComplex)) && !out.is_a?(Numo::SComplex)
            out = Numo::SComplex.cast(out)
          end
          if n == out.length
            out.inplace + d
          else
            target = out[0...n]
            target.inplace + d[0...n]
          end
        end
        out
      end

      # The volume/expression gain for the buffer, or nil without those
      # controls.
      def gain_data(count)
        @gain&.sample(count)
      end

      # Multiplies +out+ by the GM gain curve: the control product squared.
      def apply_gain(out, count)
        return out unless @gain

        g = gain_data(count)
        return nil if g.nil?

        scale(out, g)
      end

      def scale(out, gain)
        n = MB::M.min(out.length, gain.length)
        view = n == out.length ? out : out[0...n]
        g = n == gain.length ? gain : gain[0...n]
        view.inplace * g
        view.inplace * g
        out
      end
    end
  end
end
