module MB
  module Sound
    # A polyphonic synth built from a MIDI source: a MIDI::Allocator splits
    # the source's notes among voice lanes, the block builds one graph per
    # lane from a Notes instance (+v+) on that lane, and the synth sums the
    # lane graphs.  The new MIDI design's replacement for VoicePool,
    # GraphVoice, and the old offline voice split of clips (Clip#synth is
    # now this class; the public MB::Sound.synth method switches to it with
    # the synth script rewrites).
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
    # no held note and every envelope made through +v+ idle), and its level
    # (Notes#level) for the :quietest steal policy.
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
    # every lane is idle; the script runner's ringdown then stops a synth
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

      # The output controls in use (see CONTROLS).
      attr_reader :controls

      # See the class description.
      def initialize(
        source, voices: 8, spares: 2, steal: MIDI::Allocator::DEFAULT_STEAL, protect: nil, mono: nil,
        priority: :last, glide_mode: :last, controls: [], bend_range: nil, sustain: true, seed: nil,
        tail: TAIL_SECONDS, sample_rate: 48000, &block
      )
        raise ArgumentError, 'Pass a block that builds the graph of one voice from |v, index|' unless block

        @controls = Array(controls).uniq.freeze
        bad = @controls - CONTROLS
        raise ArgumentError, "Unknown synth controls #{bad} (use #{CONTROLS})" unless bad.empty?

        @sample_rate = sample_rate.to_f
        @tail = Length.seconds(tail).to_f
        @tail_samples = 0
        @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)

        stream = MIDI::Stream.for(source)
        stream = stream.bend_range(bend_range) if bend_range
        stream = stream.sustain if sustain

        @allocator = MIDI::Allocator.new(
          stream, voices: voices, spares: spares, steal: steal, protect: protect, mono: mono,
          priority: priority, glide_mode: glide_mode
        )

        @notes = []
        @lanes = @allocator.lanes.each_with_index.map { |lane, idx|
          v = Notes.new(lane, sample_rate: @sample_rate)
          graph = MB::Sound.with_seed(@seed + idx) { block.call(v, idx) }
          lane.idle_check = -> { v.idle? }
          lane.level_check = -> { v.level }
          @notes << v
          lane_outputs(graph, idx).map(&:get_sampler)
        }
        @notes.freeze

        @channels = @lanes.map(&:length).max
        @done = Array.new(@lanes.length, false)
        @buf = nil
        @channel_bufs = nil
        @sampled = []
        @frame = nil

        @control_notes = Notes.new(@allocator.stream, sample_rate: @sample_rate) unless @controls.empty?
        @gain = make_gain
        @core_outputs = @channels > 1 || @controls.include?(:pan) ? Array.new(@channels) { |c| Output.new(self, c) } : nil
        @final = make_pan

        @node_type_name = "Synth (#{@allocator.mono? ? 'mono' : "#{voices} voices"})"
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
      # to place voices yourself); don't mix the two.
      def sample_individual(count)
        any = false
        data = @lanes.each_with_index.map { |outs, idx|
          next nil if @done[idx]

          bufs = outs.map { |o| o.sample(count) }
          if bufs.any?(&:nil?)
            @done[idx] = true
            next nil
          end

          any = true
          outs.length == 1 && @channels == 1 ? bufs[0] : bufs
        }

        any ? data : nil
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
        parts << @control_notes.volume if @controls.include?(:volume)
        parts << @control_notes.expression if @controls.include?(:expression)
        return nil if parts.empty?

        node = parts.length == 1 ? parts[0] : GraphNode::Multiplier.new(parts, sample_rate: @sample_rate)
        node.get_sampler
      end

      # The pan stage (a mono synth panned, or a stereo synth balanced), or
      # nil.
      def make_pan
        return nil unless @controls.include?(:pan)

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
