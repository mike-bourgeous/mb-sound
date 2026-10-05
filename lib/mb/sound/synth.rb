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

      # The Notes instance of each lane (in lane order).
      attr_reader :notes

      # The seed of lane 0 (lane i uses seed + i; see the class
      # description).
      attr_reader :seed

      # The output controls in use (see CONTROLS; the +:controls+ given to
      # the constructor).
      attr_reader :output_controls

      # See the class description.
      def initialize(
        source, voices: 8, spares: 2, steal: MIDI::Allocator::DEFAULT_STEAL, protect: nil, mono: nil,
        priority: :last, glide_mode: :last, controls: [], bend_range: nil, sustain: true, seed: nil,
        tail: TAIL_SECONDS, skip_idle: true, sample_rate: 48000, &block
      )
        raise ArgumentError, 'Pass a block that builds the graph of one voice from |v, index|' unless block

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
          priority: priority, glide_mode: glide_mode
        )

        @notes = []
        @quiet = Array.new(@allocator.lanes.length, true)
        @lanes = @allocator.lanes.each_with_index.map { |lane, idx|
          v = Notes.new(lane, sustain: false, sample_rate: @sample_rate)
          v.quiet_check = -> { @quiet[idx] }
          graph = MB::Sound.with_seed(@seed + idx) { block.call(v, idx) }
          lane.idle_check = -> { v.idle? }
          lane.level_check = -> { v.level }
          @notes << v
          lane_outputs(graph, idx).map(&:get_sampler)
        }
        @notes.freeze

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
        any = false
        data = @lanes.each_with_index.map { |outs, idx|
          next nil if @done[idx]

          if @skipping[idx]
            case skip_lane(idx, count)
            when :ended
              @done[idx] = @quiet[idx] = true # an ended lane is silent
              next nil
            when :skipped
              any = true
              next outs.length == 1 && @channels == 1 ? zeros(count) : Array.new(outs.length) { zeros(count) }
            end
          end

          bufs = outs.map { |o| o.sample(count) }
          if bufs.any?(&:nil?)
            @done[idx] = @quiet[idx] = true
            next nil
          end

          @quiet[idx] = @notes[idx].voice_idle? && bufs.all? { |b| silent?(b) }
          @skipping[idx] = start_skipping?(idx) if @skippable[idx]

          any = true
          outs.length == 1 && @channels == 1 ? bufs[0] : bufs
        }

        any ? data : nil
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
      # channel within -120 dB) with no note held and every envelope idle
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

      # Level below which a lane's output counts as silent (-120 dB; see
      # #quiet_lanes and #setup_idle_skipping).
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
      # #setup_idle_skipping): its Notes is idle, including the quiet check
      # of the buffer just rendered (see #quiet_lanes).
      def start_skipping?(idx)
        return false unless @notes[idx].idle?

        @skip_generation[idx] = @allocator.lanes[idx].generation
        true
      end

      # True if every sample of +buf+ is within SILENCE of zero.
      def silent?(buf)
        return true if buf.equal?(@zeros)
        buf = buf.abs if buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex)
        buf.max <= SILENCE && buf.min >= -SILENCE
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
          return :ended if n.sample(count).nil?
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

      # Sums the lanes into one buffer, with the output gain.
      def mix_mono(count)
        data = sample_individual(count)
        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
        return (tail_silence(count) ? @buf.fill(0) : nil) if data.nil?

        out = sum_into(@buf, data.compact)
        apply_gain(out, count)
      end

      # Sums each channel of the lanes (narrower lanes repeat across
      # channels), with the output gain.  Returns :ended once every lane has
      # ended.
      def mix_channels(count)
        data = sample_individual(count)
        @channel_bufs = Array.new(@channels) { Numo::SFloat.zeros(count) } if @channel_bufs.nil? || @channel_bufs[0].length != count
        if data.nil?
          return :ended unless tail_silence(count)
          return @channel_bufs.map { |b| b.fill(0) }
        end

        data = data.compact

        gain = gain_data(count)
        return :ended if @gain && gain.nil?

        Array.new(@channels) { |c|
          out = sum_into(@channel_bufs[c], data.map { |bufs| bufs[c % bufs.length] })
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

      # Adds +bufs+ into +out+ (zeroed first).  Shorter buffers add to the
      # start.  Returns +out+, or a new buffer if a lane promoted the type
      # (e.g. complex).
      def sum_into(out, bufs)
        out.fill(0)
        bufs.each do |d|
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
