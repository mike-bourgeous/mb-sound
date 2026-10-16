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

      # The Plan::SharedInputs handing shared controllers to the lanes'
      # regions (nil with plans off).
      attr_reader :shared_inputs

      # The Plan::LaneGroups running the lanes' identical regions together
      # (nil with plans or lane groups off; see Plan.lanes).
      attr_reader :lane_groups

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

      # The [index, count] of the synth lane whose voice block is running on
      # this thread, or nil outside voice blocks (see MidiMethods#per_voice).
      def self.current_lane
        Thread.current[:mb_sound_synth_lane]
      end

      # Runs the block with .current_lane returning [+index+, +count+].
      def self.with_lane(index, count)
        old = Thread.current[:mb_sound_synth_lane]
        Thread.current[:mb_sound_synth_lane] = [index, count].freeze
        yield
      ensure
        Thread.current[:mb_sound_synth_lane] = old
      end

      # See the class description.
      def initialize(
        source, voices: 8, spares: 2, steal: nil, protect: nil, mono: nil,
        priority: :last, glide_mode: :last, retrigger: :reuse, controls: [], bend_range: nil, sustain: true,
        seed: nil, tail: TAIL_SECONDS, skip_idle: true, exact_lanes: false, sample_rate: 48000, &block
      )
        raise ArgumentError, 'Pass a block that builds the graph of one voice from |v, index|' unless block

        unless RETRIGGER_MODES.include?(retrigger)
          raise ArgumentError, "Unknown retrigger mode #{retrigger.inspect} (use #{RETRIGGER_MODES})"
        end
        # Set below in some configurations, or later (here first so every
        # Synth has one instance variable layout; see GraphNode::IvarPreset)
        @control_notes = nil
        @skip_idle = nil
        @skipping = nil
        @skip_generation = nil
        @cell_loud = nil
        @skip_position = nil
        @grid_offset = nil
        @zeros = nil
        @skippable_base = nil
        @boundary = nil
        @lane_sets = nil
        @boundary_cache = nil
        @clock_node = nil
        @skippable = nil
        @range = nil
        @grid_started = nil
        @joined_data = nil
        @joined_bufs = nil
        @lane_data = nil
        @lane_bufs = nil
        @piece_bufs = nil
        @lane_piece_bufs = nil
        @channel_set = nil
        @tail_generation = nil
        @sum_pairs = nil
        @sum_pool = nil
        @parts = nil
        @piece = nil
        @piece_serial = 0

        @retrigger = retrigger
        retrigger = RETRIGGER_PRESETS.fetch(retrigger, retrigger)
        steal ||= retrigger == :ring ? RING_STEAL : MIDI::Allocator::DEFAULT_STEAL
        add = retrigger == :add || retrigger == :ring || retrigger == :string

        @output_controls = Array(controls).uniq.freeze
        bad = @output_controls - CONTROLS
        raise ArgumentError, "Unknown synth controls #{bad} (use #{CONTROLS})" unless bad.empty?

        @sample_rate = sample_rate.to_f
        @tail = Length.seconds(tail).to_f
        @out_position = 0 # frames returned (see #end_frame)
        @last_event_frame = nil # where the stream's last event lands (see #tail_mode?)
        @last_loud = 0 # frame after the lanes' last loud sample since then
        @end_frame = nil
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
        @exact_lanes = !!exact_lanes
        @quiet = Array.new(@allocator.lanes.length, true)
        @quiet_pos = Array.new(@allocator.lanes.length)
        @peaks = Array.new(@allocator.lanes.length, 0.0)
        @cell_lo = Array.new(@allocator.lanes.length) { [] }
        @cell_hi = Array.new(@allocator.lanes.length) { [] }
        @cell_fresh = Array.new(@allocator.lanes.length, true)
        # Branches made while building the lanes (see #setup_idle_skipping)
        @built_branches = GraphNode::Tee.collect_branches {
          @lanes = @allocator.lanes.each_with_index.map { |lane, idx|
            v = Notes.new(lane, sustain: false, sample_rate: @sample_rate)
            v.quiet_check = -> { @quiet[idx] && (!cells? || cell_quiet?(idx)) }
            v.level_check = -> { @peaks[idx] }
            graph = Synth.with_lane(idx, @allocator.lanes.length) {
              MB::Sound.with_seed(@seed + idx) { block.call(v, idx) }
            }
            lane.idle_check = -> { @exact_lanes ? @quiet[idx] : v.idle? }
            lane.idle_position = -> { @exact_lanes ? @quiet_pos[idx] : nil }
            lane.level_check = -> { v.level }
            lane.louder_check = ->(velocity) { louder_lane?(v, velocity) }
            v.envelopes.each { |env| env.retrigger(:add) if env.respond_to?(:retrigger) } if add
            @notes << v
            outs = lane_outputs(graph, idx).map(&:get_sampler)
            prepare_skipping(outs, v) if skip_idle
            outs
          }
        }
        @notes.freeze

        # Every node of every lane's graph (see #unread_branch?)
        @lane_graphs = @lanes.map { |outs| outs.flat_map { |o| o.graph(include_tees: true) }.uniq }
        @in_lanes = {}
        @lane_graphs.each { |g| g.each { |n| @in_lanes[n.__id__] = true } }

        # Skippable parts of the lanes (see GraphNode::SubLane)
        @parts = @lane_graphs.each_with_index.map { |g, idx|
          next [].freeze unless skip_idle && Synth.sub_lanes

          parts = g.select { |n| n.is_a?(GraphNode::SubLane) && n.notes.equal?(@notes[idx]) }
          parts.each { |part| part.attach(self, @allocator.lanes[idx], g, ->(b) { unread_branch?(b) }) }
          parts.freeze
        }.freeze

        # Fused plans for each lane's graph (see MB::Sound::Plan), leaving
        # out branches nothing reads
        unread = ->(b) { unread_branch?(b) }
        @plans = @lanes.map { |outs| Plan.install(outs, lanes: false, unread: unread) }

        # Channel-wide controllers read by several lanes' regions are
        # sampled once per buffer and handed to every region (see
        # Plan::SharedInputs)
        @shared_inputs = @plans.any? ? Plan::SharedInputs.new(@plans) : nil

        # Lanes whose regions have the same shape may run them together,
        # every lane every buffer (see Plan::LaneGroup and
        # #setup_idle_skipping)
        @lane_groups = nil

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

      # Aligns the grid where lanes are measured for the allocator (see
      # #sample_lanes; SKIP_GRID samples) with the frames of a Session whose
      # frame +frame+ is the synth's first sample, so its points fall on
      # Session frames that are multiples of SKIP_GRID and 800-sample
      # Session buffers never need splitting.  Idle skipping keeps its grid
      # of the synth's own time (moving it would move where free-running
      # oscillators pause).  Called by Session when a player starts; does
      # nothing once the synth has been sampled.  Returns self.
      def align_grid(frame)
        @grid_offset = Integer(frame) % SKIP_GRID unless @grid_started
        self
      end

      # True if lanes become free for new notes by their quiet state over
      # whole cells of the measuring grid, with buffers crossing a grid
      # point read in pieces split there, so allocation is the same at any
      # buffer size (see #sample_lanes).  False (the default) measures each
      # lane per buffer, as before fixes-7: no extra CPU, but a released
      # lane may be freed at a different note at different buffer sizes.
      # Session#exact_lanes, render(exact_lanes: true), and take replays
      # turn it on for the Synths they play.
      def exact_lanes?
        @exact_lanes
      end

      # Turns exact lane allocation on or off (see #exact_lanes?); only
      # before the synth's first sample (ignored after).
      def exact_lanes=(exact)
        @exact_lanes = !!exact unless @grid_started
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

      # The indices of the lanes whose last grid cell (SKIP_GRID samples of
      # the synth's own time) was quiet (every channel within -90 dB, QUIET)
      # with no note held and every envelope idle at its end (or that
      # haven't rendered a cell yet).  A lane counts as busy for the
      # allocator (and its Notes gate and trigger keep going after a MIDI
      # file ends) until it is quiet, so voices without envelopes, such as
      # resonant filter pings, ring out.  Measured over whole cells, with
      # blocks split at the grid points (see #sample_lanes), so allocation
      # is the same for the same events at any buffer size.
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

      # Whether Synths let sub-lanes sleep (GraphNode::SubLane; true unless
      # MB_SOUND_SUB_LANES=0).  Read when a Synth is made.
      def self.sub_lanes
        @sub_lanes = ENV['MB_SOUND_SUB_LANES'] != '0' if @sub_lanes.nil?
        @sub_lanes
      end

      # Turns sub-lane skipping on or off for Synths made from now on.
      def self.sub_lanes=(enabled)
        @sub_lanes = !!enabled
      end

      # The GraphNode::SubLanes of each lane that may sleep (in lane order;
      # see #setup_idle_skipping).
      def sub_lanes
        @parts
      end

      # Used by GraphNode::SubLane: [lane index, synth sample, count, serial]
      # of the lane piece being read, or nil outside one.
      def lane_piece
        @piece
      end

      # Used by GraphNode::SubLane: calls the block with the shared
      # controller buffers showing +count+ samples from +offset+ of the
      # current lane piece (see Plan::SharedInputs#window).
      def sub_lane_window(offset, count, &block)
        shared = @shared_inputs
        return yield unless shared&.active?

        shared.window(offset, count, &block)
      end

      private

      # Runs the block with #lane_piece saying lane +idx+ is being read for
      # +count+ samples from synth sample +pos+ (only for lanes with
      # sub-lanes).
      def with_piece(idx, pos, count)
        return yield if @parts[idx].empty?

        @piece_serial += 1
        old = @piece
        @piece = [idx, pos, count, @piece_serial].freeze
        begin
          yield
        ensure
          @piece = old
        end
      end

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

      # Idle skipping's grid (samples of the synth's own time, counted from
      # its first sample): lanes (and Drums::Voice) fall asleep only on
      # its points, so the same samples are skipped at any buffer size, and
      # a run of 800-sample buffers starting with the synth sleeps as it
      # did before the grid (see #setup_idle_skipping).
      SKIP_GRID = 800

      # Node classes whose state can hold sound that comes back after a
      # silent stretch (delays, reverbs, long FIR filters) or that follow
      # the timeline (tempo LFOs), so lanes using them are never skipped.
      # MIDI transforms upstream of the allocator (echo, arp, ...) and clip
      # sources follow the timeline too but only make events, which wake
      # lanes, so they don't count (clip synths skip idle lanes since
      # 2026-10-10, user decision "yes, for now").
      def self.long_memory?(node)
        node.is_a?(GraphNode::Reverb) || node.is_a?(GraphNode::MultitapDelay) ||
          node.is_a?(GraphNode::FeedbackLoop) ||
          (node.is_a?(Sequence::TimelineNode) && !node.is_a?(MIDI::Transform) && !node.is_a?(MIDI::ClipSource)) ||
          (node.respond_to?(:base_filter) && (node.base_filter.is_a?(Filter::Delay) || node.base_filter.is_a?(Filter::FIR))) ||
          node.is_a?(Filter::Delay) || node.is_a?(Filter::FIR)
      end

      # Idle lane skipping (+:skip_idle+, on by default).  A lane is skipped
      # (its graph isn't sampled, and it outputs zeros) from a point of the
      # SKIP_GRID (every 800 samples of the synth's own time) where
      # - its Notes is idle (Notes#voice_idle?: no held note, every
      #   envelope made through it idle), and
      # - every output channel of the lane stayed within -120 dB (SILENCE)
      #   over the grid cell before it,
      # and its graph has no long-memory nodes (see .long_memory?).  Blocks
      # are split at grid points where a lane may fall asleep (see
      # #sleep_candidate), so the same samples are skipped at any buffer
      # size.  While skipped, the lane's own Notes nodes and its branches of
      # nodes shared with other lanes (controllers, bend) are still read,
      # so their readers and Tees stay in step; the lane wakes (renders
      # again) on the exact sample of its next event (note, controller,
      # choke, glide; see #wake_offset) or at a content jump.
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
        @cell_loud = Array.new(@lanes.length, false)
        @skip_position = 0
        @grid_offset = 0 # where the measuring grid starts (see #align_grid)
        @zeros = nil

        graphs = @lane_graphs
        sets = graphs.map { |g| g.to_h { |n| [n.__id__, true] } }

        @skippable_base = graphs.each_with_index.map { |g, idx|
          @skip_idle && g.none? { |n| Synth.long_memory?(n) } && g.any? { |n| n.is_a?(Notes::Node) && n.notes.equal?(@notes[idx]) }
        }

        # Lane groups compute every lane every buffer (user decision
        # 2026-10-10), so the lanes are grouped only if that gives up no
        # skipping of unfused work: each lane is never skipped anyway (it
        # has long-memory nodes, or skipping is off) or runs all of its own
        # nodes in plan regions.  Otherwise (e.g. unison oscillators outside
        # the regions) the lanes run their regions alone and idle lanes are
        # skipped as before.
        # (Sub-lanes sleep inside lanes, which a lane group computing every
        # member would break)
        if Plan.lanes && @plans.any? && @parts.all?(&:empty?) &&
            graphs.each_index.all? { |idx| !@skippable_base[idx] || lane_planned?(graphs, sets, idx) }
          @lane_groups = Plan::LaneGroups.new(@plans)
        end
        update_skippable

        # What a skipped lane still reads: its own Notes nodes, its
        # branches of Tees that others read (see #boundary), and its knob
        # readers
        @boundary = graphs.each_with_index.map { |g, idx|
          next [[], [], []] unless @skippable_base[idx]

          # Nodes read by other boundary nodes (e.g. a Glide's time input)
          # are read through them
          own = g.select { |n| n.is_a?(Notes::Node) && n.notes.equal?(@notes[idx]) }
          upstream = {}
          own.each { |n| n.graph(include_tees: true).each { |u| upstream[u.__id__] = true unless u.equal?(n) } }
          own.reject! { |n| upstream[n.__id__] }

          tee_branches = g.select { |n| n.is_a?(GraphNode::Tee::Branch) && !upstream[n.__id__] }

          # Knob readers keep their place in the Session's buffer (see
          # GraphNode::Knob::Reader), so they read past skipped stretches
          knobs = g.select { |n| n.is_a?(GraphNode::Knob::Reader) && !upstream[n.__id__] }
          [own, tee_branches, knobs]
        }
        @lane_sets = sets
        @boundary_cache = Array.new(@lanes.length)
        @clock_node = @boundary.map { |own, _, _| own.find { |n| n.is_a?(Notes::Node) } }
      end

      # Readies lane graph +outs+ (lane Notes +v+) for idle skipping while
      # building it, before the lane graphs are looked at: sub-lanes'
      # zone value indices (GraphNode::SubLane.prepare), and zone values
      # read through the Notes nodes a skipped lane keeps advancing get an
      # Index of their own (GraphNode::ZoneValue.separate).
      def prepare_skipping(outs, v)
        GraphNode::SubLane.prepare(outs, v) if Synth.sub_lanes
        g = outs.flat_map { |o| o.graph(include_tees: true) }.uniq
        return unless g.any? { |n| n.is_a?(GraphNode::ZoneValue) }

        own = GraphNode::SubLane.advanced_nodes(g.select { |n| n.is_a?(Notes::Node) && n.notes.equal?(v) })
        GraphNode::ZoneValue.separate(g, own)
      end

      # The nodes skipped lane +idx+ still reads (see #setup_idle_skipping):
      # its own Notes nodes, its knob readers, and its branches of Tees
      # read elsewhere, by another lane or by a graph outside the synth
      # (whose branch may be made after the synth), so their Tees stay in
      # step.  Branches made while building the lanes but read by no lane
      # (e.g. a `band * 0.5` left unused in the voice block) don't count:
      # reading for them would run the lane's nodes while it sleeps,
      # changing its sound.  Cached until any Tee's branches change.
      def boundary(idx)
        own, tee_branches, knobs = @boundary[idx]
        return own if tee_branches.empty? && knobs.empty?

        cache = @boundary_cache[idx]
        changes = GraphNode::Tee.branch_changes
        return cache[1] if cache && cache[0] == changes

        set = @lane_sets[idx]
        shared = tee_branches.select { |n|
          n.owner_tee.branches.any? { |b| !set[b.__id__] && !unread_branch?(b) }
        }
        list = own + shared + knobs
        @boundary_cache[idx] = [changes, list]
        list
      end

      # True if Tee branch +b+ was made while building the lanes and is in
      # no lane's graph: nothing reads it (e.g. the branch of a `band * 0.5`
      # left unused in the voice block).  Skipped lanes don't read for it
      # (see #boundary) and the plans treat it as absent (see
      # Plan::Installation#live_branches), so an unused node changes
      # neither skipping nor fusing and lane grouping.  Branches made
      # outside the synth count as readers (they may belong to a graph that
      # starts later).
      def unread_branch?(b)
        !@in_lanes[b.__id__] && !!@built_branches[b]
      end

      # True if every graph node of lane +idx+'s graph (+graphs+, with the
      # id sets +sets+; MIDI streams aren't graph nodes) other than Tees, the
      # lane's own Notes nodes, and nodes shared with other lanes is
      # computed in a plan region.
      def lane_planned?(graphs, sets, idx)
        graphs[idx].all? { |n|
          !n.is_a?(GraphNode) || n.is_a?(GraphNode::Tee) || n.is_a?(GraphNode::Tee::Branch) ||
            (n.is_a?(Notes::Node) && n.notes.equal?(@notes[idx])) ||
            sets.each_with_index.any? { |set, j| j != idx && set[n.__id__] } ||
            !n.instance_variable_get(:@plan_region).nil? || !n.instance_variable_get(:@plan_member).nil?
        }
      end

      # Lanes with regions in lane groups are computed every buffer (user
      # decision 2026-10-10: inside cross-voice regions every voice is
      # computed, so a voice costs the same whatever plays; see
      # Plan::LaneGroup), the others may be skipped while idle.
      def update_skippable
        grouped = @lane_groups ? @lane_groups.grouped_lanes : []
        @skippable = @skippable_base.each_with_index.map { |s, idx| s && !grouped.include?(idx) }
        @skippable.each_with_index { |s, idx| @skipping[idx] = false unless s }
      end

      # Records the level of lane +idx+'s channel buffers +bufs+ (for
      # Notes#level), and whether the lane is quiet (QUIET; see
      # #quiet_lanes) and silent (SILENCE; see #start_skipping?).  Quiet
      # and the level use half the peak-to-peak range, ignoring a constant
      # offset (e.g. a waveshaper's output for silence, which would keep a
      # lane busy forever); silent uses the absolute peak, since skipping
      # replaces the lane's output with zeros.
      #
      # With #exact_lanes?, measured over each grid cell (SKIP_GRID; channel
      # ranges gathered here, recorded at the grid point by #record_cells),
      # so the result is the same at any buffer size; else per buffer.
      def measure_lane(idx, bufs)
        return measure_lane_buffer(idx, bufs) unless cells?

        lo = @cell_lo[idx]
        hi = @cell_hi[idx]
        fresh = @cell_fresh[idx]
        c = 0
        while c < bufs.length
          mn, mx = range_of(bufs[c])
          if fresh || lo[c].nil?
            lo[c] = mn
            hi[c] = mx
          else
            lo[c] = mn if mn < lo[c]
            hi[c] = mx if mx > hi[c]
          end
          c += 1
        end
        @cell_fresh[idx] = false
      end

      # True if lane +idx+'s output since the last grid point (with
      # #exact_lanes?) is quiet (see #measure_lane), so a lane's Notes don't
      # count it quiet by a record made before it played.
      def cell_quiet?(idx)
        return true if @cell_fresh[idx]

        lo = @cell_lo[idx]
        hi = @cell_hi[idx]
        c = 0
        while c < lo.length
          return false if (hi[c] - lo[c]) * 0.5 > QUIET
          c += 1
        end
        true
      end

      # #measure_lane per buffer (without #exact_lanes?).
      def measure_lane_buffer(idx, bufs)
        swing = nil
        bufs.each do |b|
          mn, mx = range_of(b)
          sw = (mx - mn) * 0.5
          swing = sw if swing.nil? || sw > swing
        end
        @peaks[idx] = swing
        @quiet[idx] = @notes[idx].voice_idle? && swing <= QUIET
      end

      # Marks lane +idx+ as ended (silent from now on).
      def lane_ended(idx)
        @done[idx] = @quiet[idx] = true
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

      # The offset in the block (from +o+, of +count+) where skipped lane
      # +idx+ wakes: +o+ if its content jumped (a new generation, at the
      # start of a block), the exact sample of its next event (at the
      # offset Notes nodes give it), or nil if it stays asleep.
      def wake_offset(idx, o, count)
        lane = @allocator.lanes[idx]
        return o if lane.generation != @skip_generation[idx]

        clock = @clock_node[idx]
        from = clock.cursor
        time = lane.first_pending_time(from, clock.next_cursor(count - o))
        return nil if time.nil?

        o + ((time - from) * @sample_rate.to_r).floor
      end

      # Skips lane +idx+ for +count+ samples, reading its boundary nodes
      # (see #setup_idle_skipping): returns :ended (marking the lane
      # ended) if one of them ended, else :skipped.
      def skip_span(idx, count)
        shared = @shared_inputs
        boundary(idx).each do |n|
          # Shared controllers were read for every lane (Plan::SharedInputs)
          if shared && n.is_a?(GraphNode::Tee::Branch) && shared.shared_tee?(n.owner_tee)
            if shared.buffers[n.owner_tee.sources[:input]].nil?
              lane_ended(idx)
              return :ended
            end
            next
          end
          next if shared&.shared_node?(n)

          # Notes nodes and knob readers advance without a buffer (also
          # inside fused plans)
          if (n.is_a?(Notes::Node) || n.is_a?(GraphNode::Knob::Reader) ? n.advance(count) : n.sample(count)).nil?
            lane_ended(idx)
            return :ended
          end
        end

        parts = @parts[idx]
        i = 0
        while i < parts.length
          parts[i].lane_skipped(count)
          i += 1
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
      #
      # A block crossing a point of the synth's measuring grid (SKIP_GRID
      # samples from its first sample, or aligned with a Session's frames;
      # see #align_grid) is read in pieces split there, so every lane is on
      # the grid point when the allocator reads the events after it: lanes
      # become free for new notes by what they measured over whole grid
      # cells, at the same points at any buffer size (see #record_cells;
      # fixes-7, 2026-10-13: measured per buffer, a released lane was freed
      # at a different note at 367/368 than at 800, and the note went to
      # another lane).
      def sample_lanes(count)
        @grid_started = true
        tail = tail_mode?(count)
        return sample_lanes_piece(count) unless @exact_lanes || tail

        g = SKIP_GRID - (@skip_position + @grid_offset) % SKIP_GRID
        return sample_lanes_piece(count) if g >= count

        joined = (@joined_data ||= Array.new(@lanes.length))
        o = 0
        while o < count
          n = MB::M.min(SKIP_GRID - (@skip_position + @grid_offset) % SKIP_GRID, count - o)
          data = sample_lanes_piece(n)
          if o == 0
            return nil if data.nil?
            data.each_with_index { |d, idx| joined[idx] = d.nil? ? nil : join_piece(idx, d, 0, n, count) }
          else
            joined.each_index do |idx|
              # (lanes that ended in an earlier piece are cut short)
              next if joined[idx].nil? || entry_length(joined[idx]) < count

              d = data&.[](idx)
              joined[idx] = d.nil? ? join_end(joined[idx], o) : join_piece(idx, d, o, n, count)
            end
            break if data.nil?
          end
          o += n
        end
        joined
      end

      # Puts lane +idx+'s piece +d+ (a buffer, or an Array of channel
      # buffers, for +n+ samples) at offset +o+ of the lane's joined
      # buffers of +count+ samples (reused), returning the lane's entry (cut
      # short after a short piece: the lane ended).
      def join_piece(idx, d, o, n, count)
        bufs = d.is_a?(Array) ? d : [d]
        store = ((@joined_bufs ||= [])[idx] ||= [])
        short = false
        out = bufs.each_with_index.map { |b, c|
          t = store[c]
          t = store[c] = b.class.zeros(count) if t.nil? || t.length != count || t.class != b.class
          t[o...(o + b.length)] = b
          short ||= b.length < n
          t
        }
        entry = d.is_a?(Array) ? out : out[0]
        short ? join_end(entry, o + bufs.map(&:length).max) : entry
      end

      # The length of a lane's entry (a buffer or channel buffers).
      def entry_length(entry)
        entry.is_a?(Array) ? entry.map(&:length).max : entry.length
      end

      # A lane's joined entry +entry+ cut to its first +n+ samples (a lane
      # that ended after the first piece).
      def join_end(entry, n)
        entry.is_a?(Array) ? entry.map { |b| b[0...n] } : entry[0...n]
      end

      # One piece of #sample_lanes (not crossing a grid point).
      def sample_lanes_piece(count)
        any = false
        data = (@lane_data ||= Array.new(@lanes.length))
        shared = @shared_inputs
        shared&.begin_block(count)
        update_skippable if @lane_groups&.check
        begin
          idx = 0
          while idx < @lanes.length
            data[idx] = sample_lane(idx, count)
            any = true unless data[idx].nil?
            idx += 1
          end
        ensure
          shared&.end_block
        end
        @skip_position += count
        record_cells if cells? && (@skip_position + @grid_offset) % SKIP_GRID == 0
        check_end(any ? data : nil, @skip_position - count, @skip_position) if @last_event_frame

        any ? data : nil
      end

      # At a grid point: records each lane's level and quiet state over the
      # grid cell just ended (see #measure_lane), and where its stream was
      # (the allocator asks about lanes only for notes it sent before it),
      # for the allocator's idle checks and #quiet_lanes.
      def record_cells
        @lanes.each_index do |idx|
          next if @done[idx]

          swing = 0.0
          unless @cell_fresh[idx]
            lo = @cell_lo[idx]
            hi = @cell_hi[idx]
            c = 0
            while c < lo.length
              sw = (hi[c] - lo[c]) * 0.5
              swing = sw if sw > swing
              c += 1
            end
          end
          @cell_fresh[idx] = true
          @peaks[idx] = swing
          @quiet[idx] = @notes[idx].voice_idle? && swing <= QUIET
          @quiet_pos[idx] = @allocator.lanes[idx].source.position
        end
      end

      # One lane's entry of #sample_lanes.
      def sample_lane(idx, count)
        return nil if @done[idx]
        return sample_skippable_lane(idx, count) if @skippable[idx]

        outs = @lanes[idx]
        bufs = ((@lane_bufs ||= [])[idx] ||= [])
        bufs.clear
        ended = false
        with_piece(idx, @skip_position, count) {
          outs.each do |o|
            buf = o.sample(count)
            if buf.nil?
              ended = true
              break
            end
            bufs << buf
          end
        }
        if ended
          lane_ended(idx)
          return nil
        end

        measure_lane(idx, bufs)
        outs.length == 1 && @channels == 1 ? bufs[0] : bufs
      end

      # #sample_lane for a lane that may be skipped while idle (see
      # #setup_idle_skipping): skipped stretches give zeros, and the graph
      # is read in pieces split where the lane may fall asleep (a grid
      # point ending a silent cell, unless a held note keeps it awake) or
      # wakes (on the exact sample of its event).
      def sample_skippable_lane(idx, count)
        outs = @lanes[idx]
        pos = @skip_position
        bufs = ((@lane_bufs ||= [])[idx] ||= [])
        whole = nil
        pieces = false
        o = 0

        while o < count
          if @skipping[idx]
            wake = wake_offset(idx, o, count)
            stop = wake || count
            if stop > o
              return nil if skip_span(idx, stop - o) == :ended

              if o == 0 && wake.nil?
                whole = :zeros
              else
                pieces = true
                lane_piece_bufs(idx, outs.length, count).each { |b| b[o...stop] = 0 }
              end
            end
            o = stop
            next if wake.nil?

            @skipping[idx] = false
            @cell_loud[idx] = false
          end

          stop = sleep_candidate(idx, pos, o, count)
          piece = stop - o
          got = ((@piece_bufs ||= [])[idx] ||= [])
          got.clear
          window = o != 0 || stop != count
          ended = false
          with_piece(idx, pos + o, piece) {
            outs.each do |out|
              buf = window ? sample_window(out, o, piece) : out.sample(count)
              if buf.nil?
                ended = true
                break
              end
              if buf.length < piece
                # A lane's last buffer may be short (e.g. a resonator ringing
                # out after the lane's trigger ended stops where it falls
                # quiet): zeros after it, as for non-skippable lanes; the
                # lane ends at its next read
                padded = buf.class.zeros(piece)
                padded[0...buf.length] = buf
                buf = padded
              end
              raise "Lane #{idx} gave #{buf.length} samples, not #{piece}" if buf.length != piece
              got << buf
            end
          }
          if ended
            lane_ended(idx)
            return nil
          end

          track_lane_cells(idx, got, pos + o)

          if window
            pieces = true
            lane_piece_bufs(idx, outs.length, count).each_with_index { |b, c| b[o...stop] = got[c] }
          else
            whole = got
          end
          o = stop
        end

        if pieces
          bufs.replace(@lane_piece_bufs[idx])
        elsif whole == :zeros
          measure_lane(idx, [zeros(count)])
          return outs.length == 1 && @channels == 1 ? zeros(count) : Array.new(outs.length) { zeros(count) }
        else
          bufs.replace(whole)
        end

        measure_lane(idx, bufs)
        outs.length == 1 && @channels == 1 ? bufs[0] : bufs
      end

      # Samples lane output +out+ for +count+ samples from offset +offset+
      # of the current block (shared controller buffers are handed over
      # from there; see Plan::SharedInputs#window).
      def sample_window(out, offset, count)
        shared = @shared_inputs
        return out.sample(count) unless shared&.active?

        shared.window(offset, count) { out.sample(count) }
      end

      # The reused per-channel buffers of lane +idx+ for blocks read in
      # pieces (see #sample_skippable_lane).
      def lane_piece_bufs(idx, channels, count)
        list = ((@lane_piece_bufs ||= [])[idx] ||= [])
        list.clear if list.length != channels || (list[0] && list[0].length != count)
        list << Numo::SFloat.zeros(count) while list.length < channels
        list
      end

      # The end of the piece of the block starting at offset +o+ (of
      # +count+, the synth at sample +pos+ at offset 0) that lane +idx+
      # renders before it may fall asleep: the first grid point
      # (SKIP_GRID) whose cell may be silent, or the end of the block.  A
      # lane holding a note with no event for it in the block can't become
      # idle, so it renders the whole block.
      def sleep_candidate(idx, pos, o, count)
        g = ((pos + o) / SKIP_GRID + 1) * SKIP_GRID - pos
        return count if g > count

        g += SKIP_GRID if @cell_loud[idx]
        return count if g > count

        if @notes[idx].held?
          clock = @clock_node[idx]
          return count unless @allocator.lanes[idx].pending_before?(clock.next_cursor(count - o))
        end

        g
      end

      # Updates lane +idx+'s silent cell state (see #setup_idle_skipping)
      # for its channel buffers +bufs+ starting at synth sample +start+,
      # and starts skipping the lane at a grid point ending a silent cell
      # with the lane idle there (only the end of +bufs+, where
      # #sleep_candidate split the block; idle is known there).
      def track_lane_cells(idx, bufs, start)
        len = bufs[0].length
        i = 0
        while i < len
          g = (start + i) / SKIP_GRID * SKIP_GRID + SKIP_GRID
          stop = [g - start, len].min
          @cell_loud[idx] ||= bufs.any? { |b| lane_loud?(i == 0 && stop == len ? b : b[i...stop]) }
          if start + stop == g
            silent = !@cell_loud[idx]
            @cell_loud[idx] = false
            if silent && stop == len && @notes[idx].voice_idle?
              @skipping[idx] = true
              @skip_generation[idx] = @allocator.lanes[idx].generation
            end
          end
          i = stop
        end
      end

      # True if channel buffer +b+ has a sample beyond SILENCE.
      def lane_loud?(b)
        return false if b.equal?(@zeros)

        lo, hi = range_of(b)
        hi > SILENCE || lo < -SILENCE
      end

            # Sums the lanes into one buffer, with the output gain.
      def mix_mono(count)
        start = @out_position
        return nil if @end_frame && start >= @end_frame

        @out_position += count
        data = sample_lanes(count)
        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
        fallback_end(start) if data.nil?
        n = @end_frame ? MB::M.min(@end_frame - start, count) : count
        return n == 0 ? nil : @buf.fill(0)[0...n] if data.nil?

        out = apply_gain(sum_into(@buf, data), count)
        n < count && out ? out[0...n] : out
      end

      # Sums each channel of the lanes (narrower lanes repeat across
      # channels), with the output gain.  Returns :ended once every lane has
      # ended.
      #
      # Frames alternate between two sets of channel buffers: sampling one
      # output starts the next frame of every channel, so with one set a
      # channel's last buffer changed while a Tee was still sharing it (the
      # shared-buffer check caught a stereo synth used twice, patches-1;
      # 2026-10-13).
      def mix_channels(count)
        start = @out_position
        return :ended if @end_frame && start >= @end_frame

        @out_position += count
        data = sample_lanes(count)
        fallback_end(start) if data.nil?
        @channel_set = @channel_set == 0 ? 1 : 0
        @channel_bufs ||= [nil, nil]
        bufs = @channel_bufs[@channel_set]
        bufs = @channel_bufs[@channel_set] = Array.new(@channels) { Numo::SFloat.zeros(count) } if bufs.nil? || bufs[0].length != count
        n = @end_frame ? MB::M.min(@end_frame - start, count) : count
        if data.nil?
          return :ended if n == 0
          return bufs.map { |b| b.fill(0)[0...n] }
        end

        gain = gain_data(count)
        return :ended if @gain && gain.nil?

        Array.new(@channels) { |c|
          out = sum_into(bufs[c], data, c)
          bufs[c] = out if out.length == count && !out.equal?(bufs[c]) # a promoted (e.g. complex) buffer
          out = gain ? scale(out, gain) : out
          n < count ? out[0...n] : out
        }
      end

      # Where the synth ends once every lane has ended (nil from #sample_lanes)
      # before #check_end decided it, from frame +start+ of its output: the
      # first grid point a cell after the lanes' last loud sample (as
      # #check_end would have found), and after the stream's last event,
      # plus the +:tail+.
      def fallback_end(start)
        @end_frame ||= grid_end([@last_loud + SKIP_GRID, (@last_event_frame || 0) + 1, start].max)
      end

      # The first point of the measuring grid (SKIP_GRID, aligned like
      # #align_grid's) at or after synth frame +frame+ plus the +:tail+.
      def grid_end(frame)
        target = frame + (@tail * @sample_rate).round + @grid_offset
        (target + SKIP_GRID - 1) / SKIP_GRID * SKIP_GRID - @grid_offset
      end

      # True if the buffer of +count+ from the synth's current frame
      # reaches past the stream's last event (the synth may end inside it:
      # #sample_lanes then splits it at grid points, and #check_end looks
      # at each), working out the synth frame where that event lands
      # (+@last_event_frame+) the first time.  A seek or restart (a new
      # stream generation) starts over.
      def tail_mode?(count)
        gen = @allocator.generation
        if gen != @tail_generation
          @tail_generation = gen
          @last_event_frame = nil
          @last_loud = 0
          @end_frame = nil if @end_frame && @out_position - count < @end_frame
        end
        return true if @last_event_frame

        last = @allocator.music_end
        return false if last.nil?

        t0 = @allocator.read_to
        rate = @sample_rate.to_r
        return false unless last < t0 + Rational(count) / rate

        @last_event_frame = @skip_position + MB::M.max(((last - t0) * rate).floor, 0)
        @cell_fresh.fill(true) unless @exact_lanes # (see #cells?)
        true
      end

      # True if lanes are measured over grid cells (see #measure_lane): with
      # #exact_lanes?, or in #tail_mode? (fixes-13), where blocks are split
      # at grid points and a lane's Notes ends it only after a quiet cell
      # (measured per piece, the short pieces of the split looked quiet:
      # a resonant filter inside a lane was cut at -66 dB).
      def cells?
        @exact_lanes || !@last_event_frame.nil?
      end

      # After a piece of #sample_lanes in #tail_mode? (+data+, the lanes'
      # entries) from synth frame +from+ to +pos+: notes the lanes' last loud
      # sample (above QUIET), and at a grid point after the stream's last
      # event decides the synth's end (#end_frame) if every lane that
      # hasn't ended is idle there (Notes#voice_idle?: its notes released
      # and its envelopes idle, exactly at the point, since blocks are
      # split there) and has been quiet for the whole grid cell before it:
      # where a run of 800-sample buffers ended it before (its lanes ended
      # on the first buffer start after a quiet buffer with idle envelopes),
      # now at any buffer size (fixes-13, 2026-10-14).  Lanes still ring
      # out inside themselves as before (their Notes end by their quiet
      # checks, at buffer starts, below -90 dB).
      def check_end(data, from, pos)
        data&.each do |d|
          next if d.nil?

          (d.is_a?(Array) ? d : [d]).each do |b|
            next if b.empty?

            mn, mx = range_of(b)
            next if mx <= QUIET && mn >= -QUIET

            loud = b.abs.gt(QUIET).where
            next if loud.empty?

            e = from + loud[-1] + 1
            @last_loud = e if e > @last_loud
          end
        end

        return if @end_frame || pos <= @last_event_frame || (pos + @grid_offset) % SKIP_GRID != 0
        return if @last_loud > pos - SKIP_GRID
        return unless @notes.each_index.all? { |idx| @done[idx] || @notes[idx].voice_idle? }

        @end_frame = grid_end(pos)
      end

      # The frame of the synth's output where it ends (see #check_end), or
      # nil until it is known.  The synth returns silence after its lanes
      # up to it, a short buffer there, then nil, so it ends on the same
      # sample at any buffer size, where 800-sample buffers (from its first
      # sample, or a Session's) ended it before (fixes-13, 2026-10-14: it
      # ended at the first buffer start after its lanes had ended, so a
      # filter after it was cut -52 to -98 dB down, up to 800 samples
      # earlier or 1031 later).
      def end_frame
        @end_frame
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
