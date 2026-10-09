require 'set'

module MB
  module Sound
    module GraphNode
      # An artificial reverberation algorithm based on a presentation by
      # Geraint Luff at ADC21.  The basic algorithm is a number of
      # delay-and-mix diffusion steps followed by a feedback delay network.
      #
      # The network runs one sample at a time in C (Reverb::Network over
      # MB::Sound::FastReverb), so its feedback loops are exactly the line
      # delays at every buffer size, and it can modulate its delays and
      # process the sound inside the feedback loop (damping, highpass,
      # saturation, bit crushing, shimmer, freeze; see #initialize).
      #
      # Gains are energy-normalized for any channel, stage, input, and
      # output count: the inputs are spread over the lines at 1/sqrt(lines
      # per input), the diffusion stages' Hadamard matrices are orthogonal
      # (1/sqrt(N)), the feedback matrix is a Householder reflection, and
      # each output's group of lines is scaled by sqrt(N / group size), so
      # a +:wet:+ of 1 gives each output about the input's energy before the
      # feedback network's decay adds its own.
      #
      # See MB::Sound::GraphNode#reverb for a starting point for parameters,
      # as it's easy to make something that sounds bad.
      #
      # Reference video: https://www.youtube.com/watch?v=6ZK2Goiyotk
      #
      # Excellent reference on artificial reverb I only found after
      # implementing all of this:
      # https://ccrma.stanford.edu/~jos/pasp/Artificial_Reverberation.html
      #
      # Example (bin/sound.rb):
      #     play file_input('sounds/drums.flac').reverb
      #     play file_input('sounds/drums.flac').reverb(room_size: 0.7, decay: 3, damping: 0.4)
      class Reverb
        include GraphNode
        include GraphNode::SampleRateHelper
        include MultiOutput

        # The extra loop time (samples at FEEDBACK_BLOCK_RATE) of the
        # classic presets: until 2026-10-10 the feedback network read its
        # feedback this much later than its output taps (1024 samples, the
        # block size the presets were tuned at in 2026-01; see the git
        # history), so each loop was its line delay plus 21.3 ms.  The
        # presets keep that loop timing (+:loop_extra:+ CLASSIC_LOOP_EXTRA)
        # by reading each line at two points, so they sound as they did.
        FEEDBACK_BLOCK = 1024

        # The sample rate FEEDBACK_BLOCK is counted at.
        FEEDBACK_BLOCK_RATE = 48000

        # The classic presets' extra loop time in seconds (see
        # FEEDBACK_BLOCK).
        CLASSIC_LOOP_EXTRA = FEEDBACK_BLOCK.to_r / FEEDBACK_BLOCK_RATE

        # Feedback-stage modulation presets (see #initialize's
        # +:modulation:+).  Depths in seconds, rates in Hz, +:spread:+ the
        # per-line rate spread (rates 1 - spread to 1 + spread times
        # +:rate:+).  From common practice (CLAUDE.md, Reverbs): ValhallaRoom
        # ~0.5 Hz to smooth, >1 Hz to chorus; Dattorro's plate tank
        # ~0.17-0.27 ms at ~1 Hz; Lexicon "wander" is random.
        MODULATION = {
          subtle: { depth: 0.00025, rate: 0.5, shape: :smooth, spread: 0.3 },
          lush: { depth: 0.0008, rate: 0.8, shape: :smooth, spread: 0.3 },
          chorus: { depth: 0.002, rate: 1.5, shape: :sine, spread: 0.2 },
          seasick: { depth: 0.006, rate: 0.3, shape: :smooth, spread: 0.5 },
        }.freeze

        # Diffusion-stage modulation presets (see +:diffusion_modulation:+):
        # much shallower, since modulating short diffusers soon sounds like
        # "water sloshing around in a metal pan" (Sean Costello).
        DIFFUSION_MODULATION = {
          subtle: { depth: 0.00005, rate: 0.7, shape: :sine, spread: 0.3 },
          lush: { depth: 0.0002, rate: 0.5, shape: :smooth, spread: 0.3 },
          chorus: { depth: 0.0005, rate: 1.2, shape: :sine, spread: 0.3 },
          seasick: { depth: 0.002, rate: 0.4, shape: :smooth, spread: 0.5 },
        }.freeze

        # The largest modulation depth (seconds) the lines are sized for
        # when a depth is a node (pass +max_depth:+ in the modulation Hash
        # for more).
        DEFAULT_MAX_DEPTH = 0.01

        # Defaults of the room-size layout (see #reverb's factory form).
        ROOM_DEFAULTS = {
          room_size: 0.5,
          decay: 2.0,
          damping: 0.5,
          channels: 8,
          stages: 4,
          modulation: :subtle,
          predelay: 0,
          dry: 1,
          wet: -6.db,
          seed: 0,
        }.freeze

        # Diffusion delay range (seconds) of the room-size layout at
        # room_size 1 (scaled by 0.3 + 0.7 * room_size).
        ROOM_DIFFUSION_RANGE = 0.001..0.015

        # Feedback delay range (seconds) of the room-size layout at
        # room_size 1.
        ROOM_FEEDBACK_RANGE = 0.015..0.120

        # The gain of the pre-2026-10-10 (unnormalized) network with +n+
        # lines and +stages+ diffusion stages relative to the normalized one
        # for stereo in and out (old: every input on each of its lines at
        # gain 1, Hadamard matrices of +/-1, wet scaled by 1 / (stages *
        # n**2), or 1 / n without stages; new: see the class comment).
        # Classic presets use it as their +:level:+, so their +:wet:+ values
        # (and wet values in songs) keep their meaning and sound.
        def self.classic_level(n, stages)
          old = stages == 0 ? 1.0 / n : 1.0 / (stages * n * n)
          Math.sqrt(n / 2.0) * n**(stages / 2.0) * old / Math.sqrt(2)
        end

        # Some known-reasonable parameters for the reverb algorithm (plus an
        # extra_time value for roughly how long it takes for the reverb to ring
        # out).  The classic presets keep their 2026-01 sound and level for
        # stereo in and out (their +:level:+ is the old structure's gain, see
        # Reverb.classic_level; mono inputs and mono outputs are now as loud
        # as stereo ones, 3 dB quieter each than before).  Presets with
        # +:room_size:+ use the room-size layout.
        PRESETS = {
          room: {
            description: 'Subtle in-room reverb',
            channels: 8,
            stages: 4,
            diffusion_range: 0.01,
            feedback_range: 0.003..0.016,
            feedback_gain: 0.45,
            feedback_enabled: true,
            loop_extra: CLASSIC_LOOP_EXTRA,
            tuned_loop_extra: CLASSIC_LOOP_EXTRA,
            predelay: 0,
            dry: 1,
            wet: -16.db,
            level: classic_level(8, 4),
            seed: 0,
            extra_time: 1,
          },
          hall: {
            description: 'Something like a symphony hall',
            channels: 8,
            stages: 4,
            diffusion_range: 0.05,
            feedback_range: 0.03..0.14,
            feedback_gain: 0.9,
            feedback_enabled: true,
            loop_extra: CLASSIC_LOOP_EXTRA,
            tuned_loop_extra: CLASSIC_LOOP_EXTRA,
            predelay: 0,
            dry: 1,
            wet: -20.db,
            level: classic_level(8, 4),
            seed: 5,
            extra_time: 6,
          },
          stadium: {
            # TODO: it would be cool if the echoes panned around more
            description: 'Stadium PA echo',
            channels: 4,
            stages: 3,
            diffusion_range: 0.05,
            feedback_range: 0.3..0.45,
            feedback_gain: -4.db,
            feedback_enabled: true,
            loop_extra: CLASSIC_LOOP_EXTRA,
            tuned_loop_extra: CLASSIC_LOOP_EXTRA,
            predelay: 0,
            dry: 1,
            wet: -6.db,
            level: classic_level(4, 3),
            seed: 13,
            extra_time: 8,
          },
          space: {
            description: 'Outer space, dreaming',
            channels: 16,
            stages: 4,
            diffusion_range: 0.06,
            feedback_range: 0.2,
            feedback_gain: 0.97,
            feedback_enabled: true,
            loop_extra: CLASSIC_LOOP_EXTRA,
            tuned_loop_extra: CLASSIC_LOOP_EXTRA,
            predelay: 0.01,
            dry: 1,
            wet: -4.5.db,
            level: classic_level(16, 4),
            seed: 0,
            extra_time: 36,
          },
          plate: {
            description: 'Dense and bright, a short plate (room-size layout)',
            room_size: 0.35,
            decay: 2.2,
            damping: 0.3,
            modulation: :subtle,
            diffusion_modulation: :subtle,
            seed: 2,
          },
          shimmer: {
            description: 'A big space whose tail climbs in octaves',
            room_size: 0.8,
            decay: 6,
            damping: 0.5,
            highpass: 150,
            shimmer: 0.5,
            modulation: :lush,
            seed: 3,
          },
          grit: {
            description: 'A tail that saturates and crumbles as it decays',
            room_size: 0.6,
            decay: 4,
            damping: 0.2,
            highpass: 80,
            drive: 3,
            crush: 9,
            modulation: :subtle,
            seed: 4,
          },
          lofi: {
            description: 'Wobbly, dark, and bit crushed',
            room_size: 0.5,
            decay: 3,
            lowpass: 3000,
            highpass: 200,
            crush: 8,
            modulation: :chorus,
            seed: 5,
          },
          drone: {
            description: 'Endless ambient wash (30 s decay)',
            room_size: 1.0,
            decay: 30,
            damping: 0.6,
            highpass: 60,
            modulation: :lush,
            diffusion_modulation: :subtle,
            seed: 6,
          },
          default: {
            channels: 8,
            stages: 4,
            diffusion_range: 0.0005..0.01,
            feedback_range: 0.1,
            feedback_gain: -6.db,
            feedback_enabled: true,
            loop_extra: CLASSIC_LOOP_EXTRA,
            tuned_loop_extra: CLASSIC_LOOP_EXTRA,
            predelay: 0,
            dry: 1,
            wet: 1,
            level: classic_level(8, 4),
            seed: 0,
            extra_time: 2,
          },
        }

        # Keyword arguments of #reverb and Reverb.reverb besides +preset+
        # and +input+ (all nil by default, meaning the preset's value).
        OPTIONS = %i[
          extra_time channels stages diffusion_range feedback_range feedback_gain feedback_enabled
          predelay wet dry mix level seed show_internals loop_extra tuned_loop_extra decay room_size damping lowpass highpass drive drive_mode
          crush shimmer shimmer_pitch shimmer_window freeze stretch max_stretch modulation diffusion_modulation
          diffusion_delays feedback_delays
        ].freeze

        # For internal use by Reverb.  Represents a single output on a stereo
        # or multi-channel reverb.
        # TODO: consolidate supporting code for multi-output graph nodes.
        class ReverbOutput
          extend Forwardable
          include GraphNode
          include NodeOutput

          def_delegators :@reverb, :sample_rate, :sample_rate=, :at_rate

          attr_reader :reverb, :index

          # Creates an output handle for channel +:index+ (0-based) on the
          # given +:reverb+.
          def initialize(reverb:, index:)
            @owner = reverb
            @reverb = reverb
            @index = index
          end

          # Returns the next +count+ samples for this output channel.  Call
          # each channel only once per graph iteration.  GraphNode#get_sampler
          # helps here.
          def sample(count)
            @reverb.sample_internal(count, index: @index)
          end

          def sources
            { reverb: @reverb }
          end

          def to_s
            "Reverb output #{@index} of #{@reverb.output_channels}"
          end
        end

        # A Hash with the parameters of this Reverb.
        attr_reader :parameters

        attr_reader :output_channels, :outputs

        # The loop gain of each feedback line (see #initialize's
        # +:feedback_gain:+ and +:decay:+).
        attr_reader :gains

        # The network's delays and gains (Reverb::Network::Layout).
        attr_reader :layout

        # Wet/dry amount; large changes will cause discontinuity in audio
        # TODO: interpolate gain
        attr_accessor :wet, :dry

        # The network (Reverb::Network), nil with +:show_internals:+.
        attr_reader :network

        # See GraphNode#reverb -- this method just allows passing an input
        # array or node.  A nil +preset+ means the room-size layout if any
        # of +:room_size:+, +:decay:+, or +:damping:+ is given, else
        # :default.
        def self.reverb(preset = nil, input:, output_channels: 1, **options)
          unless input.is_a?(GraphNode) || input.is_a?(MultiOutput) || (input.is_a?(Array) && input.all?(GraphNode))
            raise 'Input must be a GraphNode, a multi-output node, or an Array of GraphNodes'
          end

          options[:modulation] = options.delete(:mod) if options.key?(:mod)
          options[:diffusion_modulation] = options.delete(:diffusion_mod) if options.key?(:diffusion_mod)
          unknown = options.keys - OPTIONS
          raise ArgumentError, "Unknown reverb options: #{unknown.join(', ')}" unless unknown.empty?

          options = options.compact
          if preset.nil?
            preset = (options.keys & [:room_size, :decay, :damping]).empty? ? :default : nil
          end

          if preset
            params = Reverb::PRESETS.fetch(preset) {
              raise ArgumentError, "Unknown reverb preset #{preset.inspect} (#{Reverb::PRESETS.keys.join(', ')})"
            }
          else
            params = { room_size: ROOM_DEFAULTS[:room_size] }
          end
          params = params.merge(options)
          params.delete(:description)
          params.delete(:feedback_gain) if options.key?(:decay) && !options.key?(:feedback_gain)

          rate = (input.is_a?(Array) ? input : input.outputs)[0].sample_rate
          params = room_params(params, sample_rate: rate) if params.key?(:room_size)
          params[:extra_time] ||= 2

          # Pad inputs with extra silence for ringdown
          #
          # Normally polymorphism is a better way to override behavior, but in
          # this specific case, the code is easier to maintain when all the logic
          # for these node DSL helper methods is in one place.
          #
          # TODO: find a way to tidy up the flow graph with these multichannel
          # inputs and outputs.
          inputs = input.is_a?(Array) ? input : input.outputs
          extra_time = MB::Sound::Length.seconds(params.delete(:extra_time), sample_rate: rate)
          if extra_time > 0 && (inputs.length > 1 || input.is_a?(Array) || input.is_a?(InputChannelSplit::InputChannelNode))
            # A separate silence node for each input so each gets the full time
            upstream = inputs.map { |i| i.and_then(MB::Sound.silence(extra_time)) }
            upstream = upstream[0] if input.is_a?(InputChannelSplit::InputChannelNode)
          else
            upstream = input
          end

          MB::Sound::GraphNode::Reverb.new(
            upstream: upstream,
            output_channels: output_channels,
            sample_rate: rate,
            **params
          )
            .tap { |n| n.named((preset || :reverb).to_s) }
            .yield_self { |n| output_channels > 1 ? Channels.new(n.outputs) : n }
        end

        # For internal use.  Fills in the room-size layout from
        # +:room_size:+ (0..1), +:decay:+, and +:damping:+ (see
        # ROOM_DEFAULTS): log-spaced random delays (stratified, rejecting
        # sets with near-integer ratios, as FdnReverb did) scaled by
        # 0.3 + 0.7 * room_size, explicit delays for #initialize.
        def self.room_params(params, sample_rate:)
          p = ROOM_DEFAULTS.merge(params)
          p.delete(:damping) if params.key?(:lowpass) && !params.key?(:damping)
          room_size = p.delete(:room_size).to_f
          raise ArgumentError, 'Room size must be between 0.0 and 1.0' unless room_size.between?(0, 1)

          decay = MB::Sound::Length.seconds(p[:decay], sample_rate: sample_rate)
          raise ArgumentError, 'Decay must be positive' unless decay > 0

          p[:extra_time] ||= [decay * 1.2 + 0.5, 60].min
          channels = Integer(p[:channels])
          stages = Integer(p[:stages])
          rng = Random.new(p[:seed] || 0)
          scale = 0.3 + 0.7 * room_size

          diff_min = ROOM_DIFFUSION_RANGE.begin
          diff_max = ROOM_DIFFUSION_RANGE.end
          p[:diffusion_delays] ||= Array.new(stages) { |step|
            step_max = diff_min + (diff_max - diff_min) * (step + 1).to_f / stages
            log_random_delays(channels, diff_min..step_max, scale, rng)
          }
          p[:feedback_delays] ||= log_random_delays(channels, ROOM_FEEDBACK_RANGE, scale, rng)
          p[:loop_extra] ||= 0
          p.delete(:feedback_gain)
          p
        end

        # Generates +n+ random delay times (in seconds) using stratified
        # log-spacing within +range+, scaled by +scale+: one random value
        # from each of +n+ equal parts of the log range.  Sets where any
        # pair has a ratio within +tolerance+ of 2, 3, or 4 are drawn again
        # (up to +max_attempts+ times) to avoid comb-filter reinforcement
        # (flutter echo).  From the removed FdnReverb.
        def self.log_random_delays(n, range, scale, rng, tolerance: 0.08, max_attempts: 50)
          log_min = Math.log(range.begin)
          log_max = Math.log(range.end)
          step = (log_max - log_min) / n.to_f

          delays = nil
          max_attempts.times do
            delays = Array.new(n) { |i|
              lo = log_min + i * step
              Math.exp(rng.rand(lo..(lo + step))) * scale
            }
            break if delays_non_harmonic?(delays, tolerance)
          end

          delays
        end

        # True if no pair of +delays+ has a ratio within +tolerance+ of 2,
        # 3, or 4.
        def self.delays_non_harmonic?(delays, tolerance)
          delays.combination(2).all? { |a, b|
            ratio = a > b ? a / b : b / a
            (2..4).none? { |int| (ratio - int).abs < tolerance }
          }
        end

        # Initializes a reverb node with the given parameters.  See
        # PRESETS for some example defaults.  Generally one would use
        # GraphNode#reverb to create a reverb.
        #
        # If +:upstream+ is a MultiOutput node, then it will split out all of
        # the outputs from that node as a multichannel input.
        #
        # Layout:
        # +:upstream+ - The source node to which to apply reverb, or an Array
        #               of source nodes.
        # +:channels+ - The number of parallel paths for diffusion and
        #               feedback.  Higher means more diffusion but more CPU
        #               usage.  Must be a power of two; try 4 to 16.
        # +:output_channels+ - The number of output channels to create.
        # +:stages+ - The number of diffusion stages.  4 is a good default.
        # +:diffusion_range+ - The diffusion delay range in seconds.  May be a
        #                      Range or a Numeric upper bound.  0.01 (10ms) is
        #                      a good starting point for experimentation.
        #                      Larger values blur the sound more but cause more
        #                      predelay.
        # +:feedback_range+ - The feedback delay range in seconds.  This should
        #                     usually be high enough that feedback doesn't amplify
        #                     audible frequencies, so at least 0.1s, but
        #                     smaller values can effectively simulate small
        #                     reverberant rooms.
        # +:diffusion_delays+, +:feedback_delays+ - explicit delays (seconds;
        #                     an Array per stage, and one per line) instead
        #                     of random draws from the ranges.
        # +:loop_extra+ - Seconds added to every feedback loop after its
        #                 output tap (0 by default; CLASSIC_LOOP_EXTRA for
        #                 the classic presets).
        # +:feedback_gain+ - The linear loop gain of every feedback line.
        #                    Must be less than 1.0 to avoid overload.
        # +:tuned_loop_extra+ - The +:loop_extra:+ the feedback gain was
        #                       chosen for (default: +:loop_extra:+); with
        #                       another loop_extra each line's gain changes
        #                       to keep its decay per second, so the classic
        #                       presets (tuned at CLASSIC_LOOP_EXTRA) keep
        #                       their RT60 with +loop_extra: 0+.
        # +:decay+ - The reverb time (RT60; seconds or any Length) instead
        #            of +:feedback_gain+: each line's gain is
        #            10 ** (-3 * loop / decay).
        # +:feedback_enabled+ - If true, feedback is included after diffusion.
        #                       If false, the feedback network is bypassed.
        # +:predelay+ - The wet signal is delayed by this amount.  Default 0.
        # +:wet+ - The reverberated signal output level.  Usually 1.0.
        # +:dry+ - The original signal output level.  Usually 1.0.
        # +:mix+ - If given, dry * (1 - mix) and wet * mix (0..1).
        # +:seed+ - Random seed Integer for reproducibility of random delays
        #           and modulation.  Try different seeds if you get unwanted
        #           ringing or echo.
        # +:show_internals+ - If true, the network runs as a graph of delay
        #                     and matrix nodes that #sources (and
        #                     graphviz) show; same sound (within float32
        #                     rounding), slower, and without modulation or
        #                     loop processing.
        #
        # Modulation (feedback stage +:modulation:+ / alias +:mod:+ in
        # #reverb; diffusion stages +:diffusion_modulation:+): nil/false
        # off, true or a MODULATION (DIFFUSION_MODULATION) key, a Length or
        # number (depth in seconds, the :subtle rest), a node (depth), or a
        # Hash of +:depth:+ (seconds, Length, or node), +:rate:+ (Hz, Pitch
        # (tempo pitches follow the tempo), or node), +:shape:+ (:sine,
        # :triangle, :random, :smooth), +:spread:+ (per-line rate spread
        # 0..1), +:max_depth:+ (line sizing for node depths), +:preset:+.
        # Feedback lines move around their delay (+/- depth), diffusion
        # lines between their delay and delay + 2 * depth.
        #
        # Inside the feedback loop (numbers or nodes unless noted):
        # +:damping:+ - 0..1 (a number): high frequencies decay faster, the
        #               reverb time at Nyquist (1 - damping) times the low
        #               reverb time (Jot's first-order absorption filters).
        # +:lowpass:+ - a one-pole lowpass cutoff (Hz or Pitch) in every
        #               line (instead of +:damping:+).
        # +:highpass:+ - a one-pole highpass cutoff (Hz) in every line.
        # +:drive:+ - saturation of the recirculated sound (level, 0 off;
        #             unity small-signal gain); +:drive_mode:+ :soft
        #             (default), :hard, or :fold (see Network::DRIVE_MODES).
        # +:crush:+ - bit depth to quantize the recirculated sound to (0
        #             off; fractional bits work).
        # +:shimmer:+ - 0..1, how much of the feedback is pitch shifted by
        #               +:shimmer_pitch:+ (an Interval or semitones, default
        #               12) through two-grain shifters of
        #               +:shimmer_window:+ (default 50 ms).
        # +:freeze:+ - 0..1: 1 mutes the input and holds the tail (loop gain
        #              1, damping and highpass bypassed).
        # +:stretch:+ - scales the feedback delays live (1 = as built; the
        #               lines are sized for +:max_stretch:+, default 2 for a
        #               node, else the number).
        def initialize(upstream:, channels:, output_channels:, stages:, sample_rate:, diffusion_range: nil, feedback_range: nil, feedback_gain: nil, feedback_enabled: true, predelay: 0, wet: 1, dry: 1, level: 1, seed: 0, show_internals: false,
                       diffusion_delays: nil, feedback_delays: nil, loop_extra: 0, tuned_loop_extra: nil, decay: nil, mix: nil, damping: nil, lowpass: nil, highpass: nil, drive: nil, drive_mode: :soft, crush: nil,
                       shimmer: nil, shimmer_pitch: 12, shimmer_window: 0.05, freeze: nil, stretch: nil, max_stretch: nil, modulation: nil, diffusion_modulation: nil)
          @random = Random.new(seed)
          @seed = seed
          @show_internals = !!show_internals

          @sample_rate = sample_rate.to_f

          @upstreams = upstream
          @upstreams = @upstreams.outputs if @upstreams.respond_to?(:outputs)
          @upstreams = [@upstreams] unless @upstreams.is_a?(Array)

          @upstreams.each_with_index do |u, idx|
            check_rate(@upstreams, "upstream #{idx}")
          end

          @channels = Integer(channels)
          @output_channels = Integer(output_channels)
          @stages = Integer(stages)

          raise 'Channels must be positive' unless @channels >= 1
          raise 'Channels must be a power of two' unless @channels == (2 ** Math.log2(@channels).floor).round
          raise 'Stages must be non-negative' unless @stages >= 0
          raise 'Output channels must be positive' unless @output_channels >= 1

          diffusion_range = 0..diffusion_range.to_f if diffusion_range.is_a?(Numeric)
          @diffusion_range = diffusion_range

          feedback_range = 0..feedback_range.to_f if feedback_range.is_a?(Numeric)
          @feedback_range = feedback_range
          @feedback_enabled = !!feedback_enabled

          @level = level.to_f
          @wet = wet.to_f
          @dry = dry.to_f
          unless mix.nil?
            mix = mix.to_f
            raise ArgumentError, 'Mix must be a number from 0 to 1' unless mix.between?(0, 1)
            @wet *= mix
            @dry *= 1 - mix
          end

          @predelay = predelay # seconds or any length
          @loop_extra = MB::Sound::Length.seconds(loop_extra || 0, sample_rate: @sample_rate).to_f
          @tuned_loop_extra = tuned_loop_extra.nil? ? @loop_extra : MB::Sound::Length.seconds(tuned_loop_extra, sample_rate: @sample_rate).to_f
          @decay = decay.nil? ? nil : MB::Sound::Length.seconds(decay, sample_rate: @sample_rate).to_f
          raise ArgumentError, 'Decay must be positive' if @decay && !(@decay > 0)
          raise ArgumentError, 'Give either damping or a lowpass' if damping && lowpass
          raise ArgumentError, 'A feedback gain or decay is required' if @feedback_enabled && !@decay && feedback_gain.nil?

          @feedback_gain = @decay ? nil : feedback_gain&.to_f

          if @output_channels > 1
            @outputs = Array.new(@output_channels) do |idx|
              ReverbOutput.new(reverb: self, index: idx)
            end.freeze
          else
            @outputs = [self].freeze
          end

          # TODO: realtime/MIDI parameter control of wet/dry
          # TODO: downmix matrix for multichannel outputs?
          # TODO: could do more complex designs for multichannel input with
          # independent or semi-independent diffusion stages, as the current
          # diffusion stage pretty fully mixes all input channels

          # Assign inputs to dry output channels.
          #
          # TODO: maybe just put N dry inputs on the first N output channels
          # without downmixing for the extra channels.  This would allow the
          # reverb to be used as a stereo-to-surround upmixing reverb.
          #
          # Example: bin/reverb.rb -p hall --input-channels 2 --output-channels 5
          @upstream_dry_groups = partition_outputs(@upstreams, @output_channels)
          @upstream_samplers = @upstream_dry_groups.map.with_index { |u, idx|
            u = u.length > 1 ? u.sum : u[0]
            u.get_sampler
          }

          # Apply predelay to input signal after dry/wet split but before
          # internal splitting/grouping
          predelayed = @upstreams.map.with_index { |u, idx|
            MB::Sound::Length.seconds(@predelay, sample_rate: @sample_rate) == 0 ? u : u.delay(@predelay).named("Predelay #{idx}")
          }

          # Assign inputs to pipeline channels, at 1/sqrt(lines per input)
          # so the inputs' energy is kept
          groups = partition_outputs(predelayed, @channels)
          appearances = Hash.new(0)
          groups.flatten.each { |u| appearances[u.object_id] += 1 }
          @input_gains = groups.map { |g| 1.0 / Math.sqrt(appearances[g[0].object_id]) }
          @line_inputs = groups.map { |u| u.length > 1 ? u.sum : u[0] }

          @layout = plan_layout(diffusion_delays: diffusion_delays, feedback_delays: feedback_delays)
          @gains = @layout.gains
          @layout.damping = damping_coefficients(damping) if damping && @feedback_enabled

          # Each output's group of lines, scaled to the energy of all lines
          @output_scales = partition_outputs(Array.new(@channels) { |i| i }, @output_channels).map { |g|
            Math.sqrt(@channels.to_f / g.length)
          }

          if @show_internals
            unsupported = {
              damping: damping, lowpass: lowpass, highpass: highpass, drive: drive, crush: crush, shimmer: shimmer,
              freeze: freeze, stretch: stretch, modulation: modulation, diffusion_modulation: diffusion_modulation,
            }.select { |_, v| v && v != 0 && v != false }
            unless unsupported.empty?
              raise ArgumentError, "show_internals can't show #{unsupported.keys.join(', ')} (only the network's delays and matrices)"
            end

            @last_stage = @line_inputs.map.with_index { |u, idx| u * @input_gains[idx] }
            @diffusers = @layout.diffusion.each_with_index.map { |st, idx|
              @last_stage = make_diffuser(st, @last_stage, idx)
            }
            @last_stage = make_fdn(@last_stage) if @feedback_enabled
          else
            @line_samplers = @line_inputs.uniq(&:object_id).map { |n| [n.object_id, n.get_sampler] }.to_h
            @last_stage = []

            if stretch.is_a?(GraphNode)
              max_stretch ||= 2
            else
              stretch = (stretch || 1).to_f
              max_stretch ||= [stretch, 1].max
            end

            shimmer_pitch = shimmer_pitch.to_semitones if shimmer_pitch.respond_to?(:to_semitones)
            @network = Network.new(
              layout: @layout,
              sample_rate: @sample_rate,
              params: {
                lowpass: hz(lowpass),
                highpass: hz(highpass),
                drive: drive || 0,
                shimmer: shimmer || 0,
                shimmer_ratio: 2.0 ** (shimmer_pitch.to_f / 12),
                freeze: freeze == true ? 1 : (freeze || 0),
                stretch: stretch,
                crush: crush || 0,
                **modulation_params(modulation, MODULATION, ''),
                **modulation_params(diffusion_modulation, DIFFUSION_MODULATION, 'diffusion_'),
              },
              diffusion_mod: @diffusion_mod,
              feedback_mod: @feedback_enabled ? @feedback_mod : nil,
              drive_mode: drive_mode,
              shimmer_window: MB::Sound::Length.seconds(shimmer_window, sample_rate: @sample_rate).to_f,
              max_stretch: max_stretch,
              seed: (seed || 0) * 1_000_003 + 0x5EED,
            )
          end

          @parameters = {
            channels: @channels,
            output_channels: @output_channels,
            stages: @stages,
            diffusion_range: @diffusion_range,
            feedback_range: @feedback_range,
            feedback_gain: @feedback_gain&.to_db,
            decay: @decay,
            loop_extra: @loop_extra,
            wet: @wet.to_db,
            dry: @dry.to_db,
            seed: seed,
            modulation: @feedback_mod&.to_h,
            diffusion_modulation: @diffusion_mod&.to_h,
          }.compact.freeze

          @sampled_set = Set.new(0...@output_channels)
          @dry_output = nil
          @pipeline_output = nil
        end

        # The reverb time (RT60 in seconds) that feedback line +idx+'s loop
        # gain gives on its own.
        def line_decay(idx)
          loop = (@layout.taps[idx] * @sample_rate).round + (@loop_extra * @sample_rate).round
          -3 * loop / @sample_rate / Math.log10(@gains[idx])
        end

        # Returns the input source, and if +:internal+ is true, the feedback
        # and diffusion network.
        def sources(internal: @show_internals)
          {
            **@upstreams.map.with_index { |u, idx|
              ["input_#{idx + 1}", u]
            }.to_h,
            **(@network ? @network.sources : {}),
            **(internal ? @last_stage.map.with_index { |v, idx| [:"channel_#{idx + 1}", v] }.to_h : {})
          }
        end

        # The loop delay of each feedback channel in samples at the current
        # rate: its tap plus +:loop_extra:+.
        def feedback_delays
          @feedback_delays ||= @layout.taps.map { |s| (s * @sample_rate).round + (@loop_extra * @sample_rate).round }.freeze
        end

        # Sets the sample rate of the upstream source and internal
        # components.  The network restarts silent.
        def sample_rate=(rate)
          @sample_rate = rate.to_f
          @feedback_delays = nil

          unless @show_internals
            @network.sample_rate = @sample_rate
            @line_samplers.each_value do |c|
              c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
            end
            return self
          end

          @diffusers.each do |stage|
            stage.each do |c|
              c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
            end
          end

          @last_stage.each do |c|
            c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
          end

          self
        end

        # For internal use.  Generates the next +count+ samples without
        # downmixing.  In graph mode (+:show_internals:+), buffers longer
        # than the shortest feedback loop (see #feedback_delays) run in
        # pieces, since the feedback for a sample must already have been
        # computed.
        def update(count)
          limit = @show_internals && @feedback_enabled ? feedback_delays.min : nil
          if limit && count > limit
            dry, wet = render_pieces(count, limit)
          else
            dry, wet = render_block(count)
          end

          if dry.nil? || wet.any?(&:nil?)
            @pipeline_output = wet
            @dry_output = nil
            return
          end

          @pipeline_output = wet

          @output_groups = partition_outputs(@pipeline_output, @output_channels)

          # (scales the dry input in place unless it's a frozen, shared
          # buffer, which is scaled into a reused buffer per channel)
          @dry_output = dry.map.with_index { |c, idx| scale_dry(c, idx) }
          @dry_groups = partition_outputs(@dry_output, @output_channels)
        end

        # Output +index+'s wet group sum times the wet gain plus its dry group
        # sum, as #sample_internal's Numo expression (Array#sum adds to 0 in
        # order), in reused buffers without allocating (FastArithmetic.mix
        # and .wet_dry), or nil to use Numo.
        def mix_output(index)
          wet = @output_groups[index]
          dry = @dry_groups[index]
          return nil if wet.empty? || dry.empty?
          length = wet[0].length

          bufs = ((@output_bufs ||= [])[index] ||= [nil, nil, [], []])
          bufs[0] = Numo::SFloat.zeros(length) unless bufs[0]&.length == length
          bufs[1] = Numo::SFloat.zeros(length) unless bufs[1]&.length == length
          wet_pairs = unity_pairs(bufs[2], wet)
          dry_pairs = unity_pairs(bufs[3], dry)

          return nil unless MB::Sound::FastArithmetic.mix(bufs[0], 0, wet_pairs) && MB::Sound::FastArithmetic.mix(bufs[1], 0, dry_pairs)
          MB::Sound::FastArithmetic.wet_dry(bufs[0], bufs[0], @wet * @level * @output_scales[index], bufs[1], 1)
        end

        # Fills reused [buffer, 1] pairs in +pairs+ for each of +bufs+.
        def unity_pairs(pairs, bufs)
          pairs.pop while pairs.length > bufs.length
          bufs.each_with_index do |b, i|
            pair = (pairs[i] ||= [nil, 1])
            pair[0] = b
          end
          pairs
        end

        # Returns dry channel +c+ (input +idx+) times the dry gain: in place,
        # or for a frozen buffer into a reused one, with
        # FastArithmetic.wet_dry for SFloat buffers and Numeric gains (the
        # same product as Numo's, (float)dry * x), else with Numo.
        def scale_dry(c, idx)
          target = c
          if c.frozen?
            bufs = (@dry_bufs ||= [])
            target = bufs[idx]
            target = bufs[idx] = c.class.zeros(c.length) unless target && target.class == c.class && target.length == c.length
          end
          return target if MB::Sound::FastArithmetic.wet_dry(target, c, @dry, c, nil)

          ((c.frozen? ? c.dup : c).inplace * @dry).not_inplace!
        end

        # For internal use.  Samples the dry inputs and the wet network for
        # +count+ samples.  Returns [dry, wet] (Arrays of channel buffers).
        def render_block(count)
          dry = @upstream_samplers.map { |u| u.sample(count) }
          wet = @show_internals ? @last_stage.map { |c| c.sample(count) } : network_wet(count)
          [dry, wet]
        end

        # For internal use.  Runs the network for +count+ samples,
        # returning the wet channels (with nil if an input or a parameter
        # node ended).
        def network_wet(count)
          bufs = @line_samplers.transform_values { |s| s.sample(count) }
          return [nil] if bufs.values.any?(&:nil?)

          n = bufs.values.map(&:length).min
          inputs = @line_inputs.map { |u| bufs[u.object_id] }
          inputs = inputs.map { |b| b.length > n ? b[0...n] : b } if inputs.any? { |b| b.length != n }
          @network.process(inputs, n) || [nil]
        end

        # For internal use.  Like #render_block, in pieces of at most +limit+
        # samples, joined.  Stops early (a shorter or nil result) if the
        # input ends.
        def render_pieces(count, limit)
          pieces = []
          done = 0
          while done < count
            n = MB::M.min(limit, count - done)
            dry, wet = render_block(n)
            break if dry.any?(&:nil?) || wet.any?(&:nil?)

            pieces << [dry.map(&:dup), wet.map(&:dup)]
            done += n
            break if (dry + wet).any? { |c| c.length < n }
          end

          return [nil, [nil]] if pieces.empty?

          join = ->(lists) { lists.transpose.map { |bufs| bufs[0].concatenate(*bufs[1..]) } }
          [join.(pieces.map(&:first)), join.(pieces.map(&:last))]
        end

        # For internal use by ReverbOutput#sample.
        def sample_internal(count, index:)
          if @sampled_set.include?(index)
            if @sampled_set.length != @output_channels
              warn "Output #{index} sampled again before all others sampled.  Sampled so far: #{@sampled_set}"
            end
            @sampled_set.clear
            update(count)
          end

          @sampled_set << index

          return nil if @dry_output.nil? || @pipeline_output.any?(&:nil?)

          mix_output(index) || begin
            wet = @output_groups[index].sum * (@wet * @level * @output_scales[index])
            (wet.inplace + @dry_groups[index].sum).not_inplace!
          end
        end

        # Generates and returns +count+ samples of the mixed dry and
        # reverberated signal.
        def sample(count)
          raise 'This is a multi-output Reverb.  Call #sample on one of the output objects.' if @output_channels != 1

          update(count)

          # TODO: automatic ringdown time?
          return nil if @dry_output.nil? || @pipeline_output.any?(&:nil?)

          @output_groups = [@pipeline_output]
          @dry_groups = [@dry_output]
          mix_output(0) || begin
            wet = @pipeline_output.sum * (@wet * @level * @output_scales[0])
            (wet.inplace + @dry_output.sum).not_inplace!
          end
        end

        private

        # A cutoff (Hz number, Pitch, or node) for the kernel, 0 if nil.
        def hz(v)
          case v
          when nil then 0
          when MB::Sound::Pitch then v.constant? ? v.frequency : v.freq
          else v
          end
        end

        # Parses a modulation setting (see #initialize) into kernel
        # parameters (+prefix+ 'diffusion_' or ''), setting @feedback_mod or
        # @diffusion_mod to a Network::Modulation (or nil).
        def modulation_params(setting, presets, prefix)
          ivar = prefix.empty? ? :@feedback_mod : :@diffusion_mod
          instance_variable_set(ivar, nil)
          settings = case setting
          when nil, false, 0
            return { :"#{prefix}depth" => 0, :"#{prefix}rate" => 0 }
          when true
            presets[:subtle]
          when Symbol
            presets.fetch(setting) { raise ArgumentError, "Unknown modulation preset #{setting.inspect} (#{presets.keys.join(', ')})" }
          when Hash
            base = presets.fetch(setting[:preset] || :subtle)
            unknown = setting.keys - [:depth, :rate, :shape, :spread, :max_depth, :preset]
            raise ArgumentError, "Unknown modulation settings: #{unknown.join(', ')}" unless unknown.empty?
            base.merge(setting.reject { |k, _| k == :preset })
          when Numeric, MB::Sound::Length::Seconds, MB::Sound::Length::Samples, MB::Sound::Sequence::Duration, GraphNode
            presets[:subtle].merge(depth: setting)
          else
            raise ArgumentError, "Invalid modulation setting #{setting.inspect}"
          end

          depth = settings[:depth]
          depth = MB::Sound::Length.seconds(depth, sample_rate: @sample_rate).to_f unless depth.is_a?(GraphNode)
          rate = settings[:rate]
          rate = hz(rate) if rate.is_a?(MB::Sound::Pitch)
          spread = settings[:spread].to_f
          shape = settings[:shape]
          raise ArgumentError, "Unknown modulation shape #{shape.inspect} (#{Network::SHAPES.keys.join(', ')})" unless Network::SHAPES.key?(shape)

          max_depth = settings[:max_depth] || (depth.is_a?(GraphNode) ? DEFAULT_MAX_DEPTH : depth)
          max_depth = MB::Sound::Length.seconds(max_depth, sample_rate: @sample_rate).to_f

          # Per-line rates spread evenly (shuffled) over 1 +/- spread, start
          # phases evenly spread (shuffled), from the reverb's seed
          rng = Random.new((@seed || 0) * 7919 + (prefix.empty? ? 101 : 202))
          count = prefix.empty? ? @channels : @channels * @stages
          scales = Array.new(count) { |i| 1.0 + spread * (count == 1 ? 0 : (2.0 * i / (count - 1) - 1)) }.shuffle(random: rng)
          phases = Array.new(count) { |i| i.to_f / count }.shuffle(random: rng)

          instance_variable_set(ivar, Network::Modulation.new(shape: shape, rate_scales: scales, phases: phases, max_depth: max_depth))

          { :"#{prefix}depth" => depth, :"#{prefix}rate" => rate }
        end

        # Draws the network's delays, polarities, shuffles, and Householder
        # normal (the same random values in the same order as before
        # 2026-10-10, so seeds keep their sound), or takes explicit delays.
        def plan_layout(diffusion_delays:, feedback_delays:)
          if diffusion_delays
            raise ArgumentError, "Need #{@stages} stages of diffusion delays" unless diffusion_delays.length == @stages

            stage_delays = diffusion_delays.map { |d|
              raise ArgumentError, "Need #{@channels} diffusion delays per stage" unless d.length == @channels
              d.map(&:to_f)
            }
          else
            delay_span = @diffusion_range.end - @diffusion_range.begin
            spans = delay_series(count: @stages, max: delay_span)
          end

          diffusion = Array.new(@stages) do |idx|
            if stage_delays
              delay_times = stage_delays[idx]
            else
              range = @diffusion_range.begin..(spans[idx] + delay_span)
              span = (range.end - range.begin).to_f
              delays = [0, *delay_series(count: @channels - 1, max: span)].shuffle(random: @random)
              delay_times = Array.new(@channels) { |c| delays[c] + range.begin }
            end
            polarity = Array.new(@channels) { @random.rand > 0.5 ? 1 : -1 }
            order = (0...@channels).to_a.shuffle(random: @random)
            { delays: delay_times, polarity: polarity, order: order }
          end

          # Normal for reflection plane for Householder matrix, making sure
          # each dimension is nonzero
          # TODO: experiment with other operations with longer repeat periods
          # like relatively prime rotations
          normal = Vector[*Array.new(@channels) { |c|
            @random.rand((c * 0.5 / @channels)..1) * (@random.rand > 0.5 ? 1 : -1)
          }].normalize.to_a

          if @feedback_enabled
            if feedback_delays
              raise ArgumentError, "Need #{@channels} feedback delays" unless feedback_delays.length == @channels
              taps = feedback_delays.map(&:to_f)
              order = (0...@channels).to_a.shuffle(random: @random)
            else
              span = @feedback_range.end - @feedback_range.begin
              delays = delay_series(count: @channels, max: span).shuffle(random: @random)
              order = (0...@channels).to_a.shuffle(random: @random)
              taps = Array.new(@channels) { |idx| (delays[idx] + @feedback_range.begin).to_f }
            end
          end

          Network::Layout.new(
            lines: @channels,
            diffusion: diffusion,
            taps: taps,
            loop_extra: @loop_extra,
            gains: taps ? loop_gains(taps) : Array.new(@channels, 0.0),
            normal: normal,
            order: order || (0...@channels).to_a,
            input_gains: @input_gains,
            damping: nil,
          )
        end

        # Each line's loop gain: from +:decay:+ (RT60 over the whole loop,
        # tap + loop_extra), or the feedback gain.
        def loop_gains(taps)
          taps.map { |t|
            loop = (t * @sample_rate).round + (@loop_extra * @sample_rate).round
            if @decay
              10.0 ** (-3.0 * loop / (@decay * @sample_rate))
            elsif @tuned_loop_extra == @loop_extra
              @feedback_gain
            else
              # The same decay per second as with loops of tap +
              # tuned_loop_extra
              tuned = (t * @sample_rate).round + (@tuned_loop_extra * @sample_rate).round
              @feedback_gain.abs ** (loop.to_f / tuned) * (@feedback_gain < 0 ? -1 : 1)
            end
          }
        end

        # Jot's first-order absorption filters (JOS, PASP, "First-Order
        # Delay-Filter Design"): for each line's loop gain g at DC, the pole
        # p = ln(10) / 4 * log10(g) * (1 - 1 / alpha**2), alpha the reverb
        # time at Nyquist over the reverb time at DC (1 - +damping+, at
        # least 0.05), so high frequencies decay faster by the same factor
        # in every line.  Returns the kernel's one-pole coefficients 1 - p.
        def damping_coefficients(damping)
          damping = damping.to_f
          raise ArgumentError, 'Damping must be between 0.0 and 1.0' unless damping.between?(0, 1)

          alpha = [1.0 - damping, 0.05].max
          @gains.map { |g|
            p = Math.log(10) / 4 * Math.log10(g.clamp(1e-9, 1.0)) * (1 - 1 / alpha**2)
            1.0 - p.clamp(0.0, 0.999)
          }
        end

        # For internal use (+:show_internals:+).  A diffusion stage as
        # graph nodes: delays, a normalized Hadamard matrix with the
        # polarities folded into its columns, and the shuffle.
        def make_diffuser(stage, input, idx)
          max = stage[:delays].max
          buffer_time = MB::M.max(max + 0.2, 1.0)
          nodes = Array.new(@channels) do |c|
            input[c]
              .delay((stage[:delays][c] * @sample_rate).round.samples, smoothing: false, max_delay: buffer_time)
              .named("Diffuse #{idx + 1} #{c + 1}")
          end

          scale = 1.0 / Math.sqrt(@channels)
          hadamard = MB::M.hadamard(@channels).map { |row|
            row.map.with_index { |v, col| v * stage[:polarity][col] * scale }
          }
          matrix = ChannelMixer::Matrix.new(nodes, matrix: hadamard, sample_rate: @sample_rate)
            .named("Hadamard #{idx + 1}")
          stage[:order].map { |o| matrix.outputs[o] }
        end

        # For internal use (+:show_internals:+).  The feedback delay
        # network as graph nodes, reading its feedback from the lines'
        # inputs (see #feedback_delays).
        def make_fdn(inputs)
          buffer_time = MB::M.max(@layout.taps.max + @loop_extra + 0.2, 1.0)

          # The inputs of the feedback delays, kept to read the feedback at
          # each loop delay (see #feedback_delays)
          @fdn_history = Array.new(inputs.length) { MB::Sound::DelayLine.new((@sample_rate * buffer_time).ceil) }

          # Add feedback from the feedback delays' inputs
          feedback = inputs.map.with_index { |inp, idx|
            inp
              .proc { |v| (@fdn_history[idx].past(v.length, feedback_delays[idx]).inplace * @gains[idx] + v).not_inplace! }
              .named("Feedback return #{idx + 1}")
          }

          normal = @layout.normal
          householder = Array.new(@channels) { |r|
            Array.new(@channels) { |c| (r == c ? 1.0 : 0.0) - 2.0 * normal[r] * normal[c] }
          }
          hhmx = ChannelMixer::Matrix.new(feedback, matrix: householder, sample_rate: @sample_rate)
            .named("Householder matrix")
          hhmx.singleton_class.define_method(:reverb) do @reverb end
          hhmx.instance_variable_set(:@reverb, self)

          delays = @layout.order.map.with_index { |o, idx|
            hhmx.outputs[o]
              .proc { |v| record_feedback_input(idx, v) }
              .named("Feedback tap #{idx + 1}")
              .delay((@layout.taps[idx] * @sample_rate).round.samples, smoothing: false, max_delay: buffer_time)
              .named("Feedback delay #{idx + 1}")
          }

          # Add feedback annotation for visualization
          delays.each_with_index do |d, idx|
            feedback[idx].with_feedback(feedback: d)
          end

          delays
        end

        # For internal use.  Records the input of feedback delay +idx+ (graph
        # mode; see #make_fdn) and passes it on.
        def record_feedback_input(idx, v)
          line = @fdn_history[idx]
          line.prepare(v.length, feedback_delays[idx])
          line.write(v)
          v
        end

        # Returns a series of randomly spaced delay times, ensuring a
        # relatively even spread.
        def delay_series(count:, max:)
          chunk_min = 0
          chunk_size = max.to_f / count
          chunk_max = chunk_size

          Array.new(count) do |i|
            @random.rand(chunk_min..chunk_max).tap { |v|
              chunk_min = v
              chunk_max += chunk_size
            }
          end
        end

        # Partitions the +list+ of objects into +count+ groups of equal size,
        # with leftovers shared across all list members.
        #
        # If +count+ is greater than the list length, then the operation is
        # basically inverted.  The list will be repeated until +count+ - 1
        # elements are reached, with the last group taking the remainder of the
        # list.  This ensures that all list elements appear the same number of
        # times.
        #
        # TODO: more complex / spatial aware mixing matrices?
        #
        # Example:
        #     partition_outputs([1, 2, 3, 4, 5], 2)
        #     # => [[1, 3, 5], [2, 4, 5]]
        #
        #     partition_outputs([1, 2], 3)
        #     # => [[1], [2], [1, 2]]
        #
        #     partition_outputs([1, 2, 3], 5)
        #     # => [[1], [2], [3], [1], [2, 3]]
        def partition_outputs(list, count)
          if count > list.length
            return Array.new(count) { |idx|
              if idx == count - 1
                # Take the remaining list elements to make sure every list
                # element occurs the same number of times
                list[(idx % list.length)..]
              else
                [list[idx % list.length]]
              end
            }
          end

          sliced = list.each_slice(count).to_a

          if sliced.last.length != count
            leftovers = sliced.pop
          end

          groups = sliced.transpose
          leftovers&.each do |l|
            groups.each do |g|
              g << l
            end
          end

          groups
        end
      end
    end
  end
end

require_relative 'reverb/network'
require_relative 'reverb/ruby_kernel'
