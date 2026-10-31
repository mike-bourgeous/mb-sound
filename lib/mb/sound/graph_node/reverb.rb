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
      # Gains are energy-normalized for any channel and stage count: the
      # inputs are spread over the lines at 1/sqrt(lines per input), the
      # diffusion stages' Hadamard matrices are orthogonal (1/sqrt(N)), the
      # feedback matrix is a Householder reflection, and each output's
      # group of lines is scaled by sqrt(N / group size), so with stereo in
      # and out a +:wet:+ of 1 gives each output about its input's energy
      # before the feedback network's decay adds its own.  Other input and
      # output counts follow Reverb.channel_trim (mono in or out +3 dB
      # each, as before 2026-10-10).
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
        # (its network's kernel, input position, and predelays move to a
        # rebuilt reverb of the same design: #carry_adopt)
        node_traits memory: :long, carry: :adopt

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
        # +:rate:+).  From common practice (design/notes/reverbs.md): ValhallaRoom
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
          damping: 0.6,
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

        # The wet level for +inputs+ input and +outputs+ output channels
        # relative to stereo in and out: 2 / sqrt(inputs * outputs), so the
        # reverb answers the inputs' mean power and spreads one total wet
        # energy over its outputs (user's decision, 2026-10-10: mono inputs
        # and mono outputs got 3 dB quieter each with the energy-normalized
        # gains; this restores the pre-2026-10-10 levels for every channel
        # count, so a mono source and the same source on both stereo
        # channels sound equally wet, a mono output carries the energy of a
        # stereo pair, and surround or per-voice bundles follow the same
        # rule: 6 outputs -4.8 dB each, 8 voice inputs -6 dB each).  Stereo
        # in and out (and the classic presets' calibration) are unchanged.
        def self.channel_trim(inputs, outputs)
          2.0 / Math.sqrt(inputs * outputs)
        end

        # Keyword arguments of #reverb and Reverb.reverb besides +preset+
        # and +input+ (all nil by default, meaning the preset's value).
        OPTIONS = %i[
          extra_time channels stages diffusion_range feedback_range feedback_gain feedback_enabled
          predelay wet dry mix level seed show_internals loop_extra tuned_loop_extra decay room_size damping damping_design lowpass highpass drive drive_mode
          crush shimmer shimmer_pitch shimmer_window freeze stretch max_stretch modulation diffusion_modulation duck gate threshold
          diffusion_delays feedback_delays
        ].freeze

        # The reverb's presets (Presettable: `sig.reverb(:hall)`,
        # Reverb.preset_settings(:hall); library files add more with
        # `reverb :name, room_size: ..., decay: ...` lines): known-reasonable
        # parameters for the reverb algorithm (plus an
        # extra_time value for roughly how long it takes for the reverb to ring
        # out).  The classic presets (:room, :hall, :stadium, :space,
        # :default) keep their 2026-01 structure and level (their +:level:+ is
        # the old structure's gain, see Reverb.classic_level; other channel
        # counts follow Reverb.channel_trim).  :stadium, :space, and :default
        # still sound exactly as in 2026-01 (impulse responses null to
        # -122..-143 dB); :room plays its wet at -10 dB (user, 2026-10-11:
        # 0 dB too wet, the original -16 dB too low; otherwise the same) and,
        # since 2026-10-10 (user's pick by ear), :hall has
        # compact loops (+loop_extra: 0+, the same decay per second).
        # Presets with +:room_size:+ use the room-size layout; their
        # +:damping:+ values were retuned on 2026-10-10 for
        # +damping_design: :exact+ (the new default) so they sound as with
        # Jot's design (the same RT60 at every frequency within 2%).
        extend MB::Sound::Presettable
        preset_family :reverb, kind: :effect, keys: OPTIONS,
          about: 'Reverb settings: sig.reverb(:hall), [l, r].reverb(:plate, mix: 0.3)',
          apply: ->(name, input, **options) { input.reverb(name, **options) },
          code: ->(e) { "sig.reverb(#{e.name.inspect})" }

        param :room_size, 0.5, range: 0.0..1.0, description: 'Room size (room-size layout)'
        param :decay, 2.0, range: 0.1..60.0, curve: :exp, unit: 's', description: 'Decay time (RT60) in seconds'
        param :damping, 0.6, range: 0.0..1.0, description: 'High-frequency damping'
        param :mix, 0.5, description: 'Dry/wet mix'

        preset :room, about: 'Subtle in-room reverb', tags: %i[small subtle],
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
          wet: -10.db, # since 2026-10-11 (user: 0 dB too wet, -16 dB too low)
          level: classic_level(8, 4),
          seed: 0,
          extra_time: 1

        preset :hall, about: 'Something like a symphony hall', tags: %i[big classic],
          channels: 8,
          stages: 4,
          diffusion_range: 0.05,
          feedback_range: 0.03..0.14,
          feedback_gain: 0.9,
          feedback_enabled: true,
          # Compact loops since 2026-10-10 (user's pick by ear): the line
          # delays alone, gains retuned to the classic decay per second
          loop_extra: 0,
          tuned_loop_extra: CLASSIC_LOOP_EXTRA,
          predelay: 0,
          dry: 1,
          wet: -20.db,
          level: classic_level(8, 4),
          seed: 5,
          extra_time: 6

        preset :stadium, about: 'Stadium PA echo', tags: %i[echo huge],
          # TODO: it would be cool if the echoes panned around more
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
          extra_time: 8

        preset :space, about: 'Outer space, dreaming', tags: %i[huge dreamy],
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
          extra_time: 36

        preset :plate, about: 'Dense and bright, a short plate (room-size layout)', tags: %i[bright dense short],
          room_size: 0.35,
          decay: 2.2,
          damping: 0.34,
          modulation: :subtle,
          diffusion_modulation: :subtle,
          seed: 2

        preset :shimmer, about: 'A big space whose tail climbs in octaves', tags: %i[big octaves dreamy],
          room_size: 0.8,
          decay: 6,
          damping: 0.6,
          highpass: 150,
          shimmer: 0.5,
          modulation: :lush,
          seed: 3

        preset :grit, about: 'A tail that saturates and crumbles as it decays', tags: %i[dirty saturated],
          room_size: 0.6,
          decay: 4,
          damping: 0.22,
          highpass: 80,
          drive: 3,
          crush: 9,
          modulation: :subtle,
          seed: 4

        preset :lofi, about: 'Wobbly, dark, and bit crushed', tags: %i[dark wobbly crushed],
          room_size: 0.5,
          decay: 3,
          lowpass: 3000,
          highpass: 200,
          crush: 8,
          modulation: :chorus,
          seed: 5

        preset :gated, about: '1980s gated reverb: a big room cut off 0.25 s after the hit', tags: %i[eighties short],
          room_size: 0.7,
          decay: 2.5,
          damping: 0.34,
          gate: 0.25,
          threshold: -30.db,
          modulation: false,
          seed: 7

        preset :drone, about: 'Endless ambient wash (30 s decay)', tags: %i[endless ambient],
          room_size: 1.0,
          decay: 30,
          damping: 0.72,
          highpass: 60,
          modulation: :lush,
          diffusion_modulation: :subtle,
          seed: 6

        preset :default, tags: %i[classic],
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
          extra_time: 2

        # For internal use by Reverb.  Represents a single output on a stereo
        # or multi-channel reverb.
        # TODO: consolidate supporting code for multi-output graph nodes.
        class ReverbOutput
          extend Forwardable
          include GraphNode
          include NodeOutput
          node_traits memory: :none

          def_delegators :@reverb, :sample_rate, :sample_rate=, :at_rate

          # The output channel index (0-based).  The Reverb itself is @reverb
          # (no reader: +reverb+ is the DSL method that adds another reverb).
          attr_reader :index

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

        # For internal use by Reverb.  One input of a reverb with several
        # inputs: passes its source through, and once the source ends, plays
        # silence while any other input of its group still plays (as
        # Dynamics does), ending (nil) only when every input has ended.  A
        # short buffer is the source's last, padded with zeros to the
        # requested length; #end_position tells the Reverb where the source
        # ended, so its output ends where the last input did.  (Before
        # 2026-10-12, an input ending early, e.g.
        # `stereo(saw * one_shot_env, saw).reverb`, cut the network's block
        # short against the full dry buffers: a ShapeError.)
        class PaddedInput
          include GraphNode
          include SampleRateHelper
          # (a position, moved by its Reverb's #carry_adopt)
          node_traits memory: :short, carry: :none

          # One PaddedInput per source, sharing their ended flags.
          def self.group(sources)
            ended = Array.new(sources.length, false)
            sources.map.with_index { |s, idx| new(s, ended: ended, index: idx) }
          end

          # The position (samples from the start) where the source ended,
          # or nil while it plays.  Positions count every sample returned,
          # so they stay right when a Tee reads ahead.
          attr_reader :end_position

          # The ended flags shared by the group (see .group).
          attr_reader :ended

          def initialize(source, ended:, index:)
            @source = source.get_sampler
            @ended = ended
            @index = index
            @position = 0
            @end_position = nil
            @sample_rate = @source.sample_rate.to_f
            @node_type_name = "Reverb input #{index + 1}"
          end

          def sources
            { input: @source }
          end

          # Swaps positions with padded input +old+ (Reverb#carry_adopt
          # swaps the group's ended flags).
          def carry_adopt(old)
            NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
          end

          ADOPT_IVARS = %i[@position @end_position].freeze

          # The source's next +count+ samples, or silence after it ends
          # while another input plays, else nil.
          def sample(count)
            unless @ended[@index]
              buf = @source.sample(count)
              if buf.nil? || buf.empty?
                @ended[@index] = true
                @end_position = @position
              elsif buf.length >= count
                @position += buf.length
                return buf
              else
                @ended[@index] = true
                @end_position = @position + buf.length
                @position += count

                @pad = buf.class.zeros(count) unless @pad.class == buf.class && @pad.length == count
                BufferHelper.zero(@pad)
                @pad[0...buf.length] = buf
                return @pad
              end
            end

            return nil if @ended.all?

            @position += count
            @silence = Numo::SFloat.zeros(count).freeze unless @silence&.length == count
            @silence
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

        # The wet and dry gains (after +:mix:+ for numbers): numbers or
        # sampler branches of graph nodes, read every sample.  A number
        # jumps at the next buffer; a node (a knob, a smoothed control)
        # moves the gain smoothly.
        attr_reader :wet, :dry

        # The overall wet level (a number or a node), and the +:mix:+ when it
        # is a node or the wet or dry gain is (else nil: folded into them).
        attr_reader :level, :mix

        # Sets the wet gain (a number or a graph node; see #wet).
        def wet=(gain)
          @wet = gain_input(gain, 'wet')
          update_live
        end

        # Sets the dry gain (a number or a graph node; see #dry).
        def dry=(gain)
          @dry = gain_input(gain, 'dry')
          update_live
        end

        # The network (Reverb::Network).
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
            params = Reverb.preset_settings(preset)
          else
            params = { room_size: ROOM_DEFAULTS[:room_size] }
          end
          params = params.merge(options)
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
          if extra_time > 0
            # A separate silence node for each input so each gets the full
            # time (single nodes too since 2026-10-10: before, a reverb fed
            # by one node ended with its input, cutting the tail)
            upstream = inputs.map { |i| i.and_then(MB::Sound.silence(extra_time)) }
            upstream = upstream[0] unless input.is_a?(Array) || inputs.length > 1
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
        # Reverb.presets for some example defaults.  Generally one would use
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
        # +:predelay+ - The wet signal is delayed by this amount (any length,
        #               or a node: the read position glides).  Default 0.
        # +:wet+ - The reverberated signal output level.  Usually 1.0.
        # +:dry+ - The original signal output level.  Usually 1.0.
        # +:mix+ - If given, dry * (1 - mix) and wet * mix (0..1).
        #          +:wet+, +:dry+, +:mix+, and +:level+ are numbers or nodes
        #          (knobs) read every sample after the network (delays-2).
        # +:seed+ - Random seed Integer for reproducibility of random delays
        #           and modulation.  Try different seeds if you get unwanted
        #           ringing or echo.
        # +:show_internals+ - If true, graphviz drawings (GraphNode#graphviz,
        #                     --graphviz) show the network's layout inside
        #                     the reverb: its input gains, diffusion stages
        #                     (delays, polarities, Hadamard mixing, shuffle),
        #                     and feedback lines (delays, loop gains, taps,
        #                     Householder feedback), drawn from
        #                     Reverb::Network's Layout (see
        #                     #graphviz_internals).  The sound is unchanged.
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
        #               reverb time (first-order absorption filters in every line).
        # +:damping_design:+ - :exact (default since 2026-10-10; see
        #               #damping_coefficients) or :jot (Jot's approximate
        #               pole, the default before: it damps more than asked,
        #               e.g. Jot 0.5 = exact 0.6, and kills the longer lines
        #               above about 0.7).
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
        # After the network (on the wet sound, keyed by the input's peak):
        # +:duck:+ - how far the wet sound ducks while the input is above
        #            +:threshold:+ (-12.db or 12.db both duck by 12 dB; a
        #            bare number is a linear gain at most 1, see
        #            Decibels.reduction_db; a node gives dB of reduction,
        #            12 for 12 dB), falling in 10 ms and
        #            recovering over 300 ms, so the reverb blooms in the
        #            gaps.
        # +:gate:+ - seconds (or a Length) the wet sound stays open after
        #            the input falls below +:threshold:+, then closes over
        #            20 ms: the classic gated reverb (big room or plate,
        #            gate 0.2-0.4 s, on drums).
        # +:threshold:+ - the input peak level for both (default -30 dB).
        #
        # +:stretch:+ - scales the feedback delays live (1 = as built; the
        #               lines are sized for +:max_stretch:+, default 2 for a
        #               node, else the number).
        def initialize(upstream:, channels:, output_channels:, stages:, sample_rate:, diffusion_range: nil, feedback_range: nil, feedback_gain: nil, feedback_enabled: true, predelay: 0, wet: 1, dry: 1, level: 1, seed: 0, show_internals: false,
                       diffusion_delays: nil, feedback_delays: nil, loop_extra: 0, tuned_loop_extra: nil, decay: nil, mix: nil, damping: nil, damping_design: :exact, lowpass: nil, highpass: nil, drive: nil, drive_mode: :soft, crush: nil,
                       shimmer: nil, shimmer_pitch: 12, shimmer_window: 0.05, freeze: nil, stretch: nil, max_stretch: nil, modulation: nil, diffusion_modulation: nil,
                       duck: nil, gate: nil, threshold: -30.db)
          @random = Random.new(seed)
          @seed = seed
          @show_internals = !!show_internals

          # Set in only some configurations, or later (here so every Reverb
          # has one instance variable layout; see GraphNode::IvarPreset)
          @padded_inputs = nil
          @predelays = nil
          @line_samplers = nil
          @network = nil
          @feedback_mod = nil
          @diffusion_mod = nil
          @feedback_delays = nil
          @output_groups = nil
          @dry_groups = nil
          @output_bufs = nil
          @dry_bufs = nil
          @partitions = {} # (reused groups for #update; see #partition_reused)
          @dry_scaled = []
          # (reused by #render_block and #network_wet every buffer; dropouts-2)
          @block_dry = []
          @block_pair = [nil, nil]
          @line_bufs = {}
          @line_input_bufs = []

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

          # Output gains (delays-2, 2026-10-31: the maintainer's "Mix should
          # just be a gain control that can be adjusted with a knob, no
          # rebuild needed"): numbers or nodes read every sample after the
          # network.  Numbers fold +:mix:+ into the wet and dry gains here,
          # as always (the same samples as before); a node anywhere makes
          # the gains per-sample buffers (see #live_gains).
          @level = gain_input(level, 'level')
          @wet = gain_input(wet, 'wet')
          @dry = gain_input(dry, 'dry')
          @mix = nil
          @live_held = {} # (each gain node's last value, held if it ends, and its steady-buffer cache)
          @live_range = [0.0, 0.0] # (reused by #gain_values)
          @live_wet = nil
          @live_dry = nil
          unless mix.nil?
            mix = gain_input(mix, 'mix')
            raise ArgumentError, 'Mix must be a number from 0 to 1' if mix.is_a?(Float) && !mix.between?(0, 1)
            if [@level, @wet, @dry, mix].all?(Float)
              @wet *= mix
              @dry *= 1 - mix
            else
              @mix = mix
            end
          end
          update_live

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
          # With several inputs, an input that ends plays silence until they
          # all end (see PaddedInput).
          @padded_inputs = PaddedInput.group(@upstreams) if @upstreams.length > 1
          @input_position = 0
          inputs = @padded_inputs || @upstreams

          @upstream_dry_groups = partition_outputs(inputs, @output_channels)
          @upstream_samplers = @upstream_dry_groups.map.with_index { |u, idx|
            u = u.length > 1 ? u.sum : u[0]
            u.get_sampler
          }

          # Apply predelay to input signal after dry/wet split but before
          # internal splitting/grouping
          predelayed = inputs.map.with_index { |u, idx|
            # (a node predelay moves live: #delay's smoothed read position
            # glides to each new time at its slew limit)
            !@predelay.respond_to?(:sample) && MB::Sound::Length.seconds(@predelay, sample_rate: @sample_rate) == 0 ? u : u.delay(@predelay, ring_out: false).named("Predelay #{idx}")
          }
          @predelays = predelayed.reject.with_index { |u, idx| u.equal?(inputs[idx]) }.freeze # (see #carry_adopt)

          # Assign inputs to pipeline channels, at 1/sqrt(lines per input)
          # so the inputs' energy is kept
          groups = partition_outputs(predelayed, @channels)
          appearances = Hash.new(0)
          groups.flatten.each { |u| appearances[u.object_id] += 1 }
          @input_gains = groups.map { |g| 1.0 / Math.sqrt(appearances[g[0].object_id]) }
          @line_inputs = groups.map { |u| u.length > 1 ? u.sum : u[0] }

          @layout = plan_layout(diffusion_delays: diffusion_delays, feedback_delays: feedback_delays)
          @gains = @layout.gains
          @layout.damping = damping_coefficients(damping, design: damping_design) if damping && @feedback_enabled

          # Each output's group of lines, scaled to the energy of all lines,
          # then by the channel-count trim (see Reverb.channel_trim)
          @channel_trim = self.class.channel_trim(@upstreams.length, @output_channels)
          @output_scales = partition_outputs(Array.new(@channels) { |i| i }, @output_channels).map { |g|
            Math.sqrt(@channels.to_f / g.length) * @channel_trim
          }

          @line_samplers = @line_inputs.uniq(&:object_id).map { |n| [n.object_id, n.get_sampler] }.to_h

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
              duck: duck_db(duck),
              gate: gate.is_a?(GraphNode) ? gate : MB::Sound::Length.seconds(gate || 0, sample_rate: @sample_rate).to_f,
              threshold: threshold,
              **modulation_params(modulation, MODULATION, ''),
              **modulation_params(diffusion_modulation, DIFFUSION_MODULATION, 'diffusion_'),
            },
            diffusion_mod: @diffusion_mod,
            feedback_mod: @feedback_enabled ? @feedback_mod : nil,
            drive_mode: drive_mode,
            shimmer_window: MB::Sound::Length.seconds(shimmer_window, sample_rate: @sample_rate).to_f,
            max_stretch: max_stretch,
            seed: (seed || 0) * 1_000_003 + 0x5EED,
            dynamics: [duck_db(duck), gate].any? { |v| v.is_a?(GraphNode) || (v && v != 0) },
          )

          @parameters = {
            channels: @channels,
            output_channels: @output_channels,
            stages: @stages,
            diffusion_range: @diffusion_range,
            feedback_range: @feedback_range,
            feedback_gain: @feedback_gain&.to_db,
            decay: @decay,
            loop_extra: @loop_extra,
            wet: @wet.is_a?(Float) ? @wet.to_db : @wet.to_s,
            dry: @dry.is_a?(Float) ? @dry.to_db : @dry.to_s,
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

        # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true if
        # reverb +old+'s network runs the same kernel design (lines, delays,
        # gains, modulation, seed) with as many inputs and predelays, so its
        # state continues in this one.  Another room size or decay doesn't
        # fit.
        def carry_fits?(old)
          return false unless old.class == self.class
          a = old.network
          b = @network
          ip = old.instance_variable_get(:@padded_inputs)
          a.config == b.config && ip&.length == @padded_inputs&.length &&
            old.predelays.length == @predelays.length && old.predelays.zip(@predelays).all? { |x, y| y.carry_fits?(x) }
        end

        # Takes over reverb +old+'s network state (its kernel object: lines,
        # modulation phases, smoothers), input position, padded inputs, and
        # predelay lines; the old one gets this one's fresh state.  On the
        # swap frame; O(1).
        def carry_adopt(old)
          @network.swap_kernel(old.network)
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
          op = old.instance_variable_get(:@padded_inputs)
          if @padded_inputs
            @padded_inputs.zip(op).each { |a, b| a.carry_adopt(b) }
            NodeTraits.swap_contents(@padded_inputs[0].ended, op[0].ended)
          end
          @predelays.zip(old.predelays).each { |a, b| a.carry_adopt(b) }
        end

        # The reverb's own running state #carry_adopt swaps.
        ADOPT_IVARS = %i[@input_position].freeze

        # The predelay nodes (an Array, empty without a predelay).
        attr_reader :predelays

        # Returns the input sources and the network's live parameter nodes.
        def sources
          {
            **@upstreams.map.with_index { |u, idx|
              ["input_#{idx + 1}", u]
            }.to_h,
            **@network.sources,
            **{ wet: @wet, dry: @dry, level: @level, mix: @mix, predelay: @predelay }.select { |_, v| v.respond_to?(:sample) },
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

          @network.sample_rate = @sample_rate
          @line_samplers.each_value do |c|
            c.sample_rate = @sample_rate unless c.sample_rate == @sample_rate
          end
          self
        end

        # For internal use.  Generates the next +count+ samples without
        # downmixing.
        def update(count)
          dry, wet = render_block(count)

          if dry.nil? || wet.any?(&:nil?)
            @pipeline_output = wet
            @dry_output = nil
            return
          end

          @pipeline_output = wet

          live_gains(dry[0].length) if @live

          @output_groups = partition_reused(:wet, @pipeline_output, @output_channels)

          # (scales the dry input in place unless it's a frozen, shared
          # buffer, which is scaled into a reused buffer per channel)
          @dry_scaled.clear
          idx = -1
          @dry_scaled << scale_dry(dry[idx], idx) while (idx += 1) < dry.length # (no each_with_index: an imemo a call)
          @dry_output = @dry_scaled
          @dry_groups = partition_reused(:dry, @dry_output, @output_channels)
        end

        # Output +index+'s wet group sum times the wet gain plus its dry group
        # sum, as #sample_internal's Numo expression (Array#sum adds to 0 in
        # order), in reused buffers without allocating (Kernels.mix
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

          return nil unless MB::Sound::Kernels.mix(bufs[0], 0, wet_pairs) && MB::Sound::Kernels.mix(bufs[1], 0, dry_pairs)
          gain = wet_gain(index)
          return MB::Sound::Kernels.wet_dry(bufs[0], bufs[0], gain, bufs[1], 1) if gain.is_a?(Numeric)

          # (live gains: the same products, rounded to float, then the sum)
          bufs[0].inplace * gain
          (bufs[0].inplace + bufs[1]).not_inplace!
        end

        # Output +index+'s wet gain: a number, or with live gains (see
        # #live_gains) a per-sample SFloat buffer.
        def wet_gain(index)
          return @wet * @level * @output_scales[index] unless @live

          g = @live_wet * @output_scales[index]
          g.is_a?(Numeric) ? g : Numo::SFloat.cast(g)
        end

        # The output gains as numbers or graph nodes' sampler branches
        # (#initialize's +:wet:+, +:dry:+, +:level:+, +:mix:+).
        def gain_input(value, name)
          if value.respond_to?(:sample)
            value = value.get_sampler
            check_rate(value, name)
            value
          elsif value.is_a?(Numeric) && value.real?
            value.to_f
          else
            raise ArgumentError, "Reverb #{name} must be a real number or a graph node (got #{value.inspect})"
          end
        end

        # Whether any output gain is a node (read every sample).
        def update_live
          @live = [@wet, @dry, @level, @mix].any? { |v| v.respond_to?(:sample) }
        end

        # Computes the wet gain (+:wet:+ x +:mix:+ x +:level:+, before each
        # output's scale) and the dry gain (+:dry:+ x (1 - +:mix:+)) for
        # the next +n+ samples, each a number or a DFloat buffer, in the
        # order the numbers fold (the same gains at a node's constant
        # value; a node's float32 values may differ from a Ruby literal's).
        # A +:mix:+ node is clamped to 0..1.
        def live_gains(n)
          w = gain_values(@wet, n)
          d = gain_values(@dry, n)
          l = gain_values(@level, n)
          m = @mix.nil? ? nil : gain_values(@mix, n)
          m = m.is_a?(Numeric) ? m.clamp(0.0, 1.0) : m.clip(0.0, 1.0) unless m.nil?
          @live_wet = m.nil? ? w * l : w * m * l
          @live_dry = m.nil? ? d : d * (1 - m)
        end

        # +n+ values of gain +src+: the number, or the node's next samples as
        # a DFloat (a short or ended node holds its last value).  A node
        # buffer whose samples are all one value (a knob at rest) gives that
        # number, so steady knobs mix through the numeric path: the same
        # samples, at a number's cost (a frozen buffer seen before is
        # recognized by its GraphNode::FrozenView::Key without a scan).
        def gain_values(src, n)
          return src unless src.respond_to?(:sample)

          held = @live_held[src.object_id]
          buf = src.sample(n)
          return held&.[](0) || 0.0 if buf.nil? || buf.empty?

          buf = buf.real if buf.is_a?(Numo::SComplex) || buf.is_a?(Numo::DComplex)
          held ||= (@live_held[src.object_id] = [0.0, FrozenView::Key.new, nil])
          if buf.length >= n && held[1].match?(buf)
            v = held[2]
          else
            held[1].set(buf)
            r = @live_range
            unless MB::Sound::Kernels.min_max(buf, r)
              r[0] = buf.min.to_f
              r[1] = buf.max.to_f
            end
            v = r[0] == r[1] ? r[0] : nil
            held[2] = v
          end
          if v
            held[0] = v
            return v
          end

          v = Numo::DFloat.cast(buf.length > n ? buf[0...n] : buf)
          if v.length < n
            full = Numo::DFloat.new(n).fill(v[-1])
            full[0...v.length] = v
            v = full
          end
          held[0] = v[-1]
          v
        end

        # Fills reused [buffer, 1] pairs in +pairs+ for each of +bufs+.
        def unity_pairs(pairs, bufs)
          pairs.pop while pairs.length > bufs.length
          i = -1
          while (i += 1) < bufs.length # (no each_with_index: an imemo a call)
            pair = (pairs[i] ||= [nil, 1])
            pair[0] = bufs[i]
          end
          pairs
        end

        # Returns dry channel +c+ (input +idx+) times the dry gain: in place,
        # or for a frozen buffer into a reused one, with
        # Kernels.wet_dry for SFloat buffers and Numeric gains (the
        # same product as Numo's, (float)dry * x), else with Numo.
        def scale_dry(c, idx)
          target = c
          if c.frozen?
            bufs = (@dry_bufs ||= [])
            target = bufs[idx]
            target = bufs[idx] = c.class.zeros(c.length) unless target && target.class == c.class && target.length == c.length
          end
          gain = @live ? @live_dry : @dry
          unless gain.is_a?(Numeric)
            # (live gains: the gain rounded to float times each sample)
            g = Numo::SFloat.cast(gain)
            return c * g if c.frozen?
            return (c.inplace * g).not_inplace!
          end
          return target if MB::Sound::Kernels.wet_dry(target, c, gain, c, nil)

          ((c.frozen? ? c.dup : c).inplace * gain).not_inplace!
        end

        # For internal use.  Samples the dry inputs and the wet network for
        # +count+ samples.  Returns [dry, wet] (Arrays of channel buffers).
        def render_block(count)
          # (reused Arrays, no Hash or Enumerator: this runs every buffer;
          # dropouts-2)
          dry = @block_dry
          dry.clear
          ups = @upstream_samplers
          i = 0
          while i < ups.length
            dry << ups[i].sample(count)
            i += 1
          end
          wet = network_wet(count)

          # After every input's source has ended (the ended ones padded with
          # silence; see PaddedInput), the output ends where the last of
          # them did
          # (any?(&:nil?), not include?(nil): NArray#== casts nil to an
          # NArray, ~9000 objects a second)
          unless dry.any?(&:nil?) || wet.any?(&:nil?)
            n = nil
            dry.each { |b| n = b.length if n.nil? || b.length < n }
            wet.each { |b| n = b.length if n.nil? || b.length < n }
            if @padded_inputs && @padded_inputs.all?(&:end_position)
              n = MB::M.min(n, @padded_inputs.map(&:end_position).max - @input_position)
              return [dry, [nil]] if n <= 0
            end
            @input_position += n

            if dry.any? { |b| b.length != n } || wet.any? { |b| b.length != n }
              cut = ->(b) { b.length > n ? (b.frozen? ? b[0...n].dup.freeze : b[0...n]) : b }
              dry = dry.map(&cut)
              wet = wet.map(&cut)
            end
          end

          @block_pair[0] = dry
          @block_pair[1] = wet
          @block_pair
        end

        # #partition_outputs of +list+ into Arrays reused from buffer to
        # buffer (one set per +key+): the grouping depends only on the
        # lengths, so it is planned once as indices (alloc-2).
        def partition_reused(key, list, count)
          plan, groups = @partitions[key]
          if plan.nil? || plan[0] != list.length || plan[1] != count
            idx = partition_outputs((0...list.length).to_a, count)
            groups = idx.map { |g| Array.new(g.length) }
            @partitions[key] = [[list.length, count, idx], groups]
            plan = @partitions[key][0]
          end
          gi = -1
          while (gi += 1) < plan[2].length # (no each_with_index: imemos every buffer)
            g = plan[2][gi]
            out = groups[gi]
            j = -1
            out[j] = list[g[j]] while (j += 1) < g.length
          end
          groups
        end

        # For internal use.  Runs the network for +count+ samples,
        # returning the wet channels (with nil if an input or a parameter
        # node ended).
        def network_wet(count)
          bufs = @line_bufs
          ended = false
          n = nil
          @line_samplers.each_pair do |id, sampler|
            b = sampler.sample(count)
            bufs[id] = b
            if b.nil?
              ended = true
            elsif n.nil? || b.length < n
              n = b.length
            end
          end
          return [nil] if ended

          inputs = @line_input_bufs
          i = -1
          while (i += 1) < @line_inputs.length # (no each_with_index: an imemo a call)
            b = bufs[@line_inputs[i].object_id]
            inputs[i] = b.length > n ? b[0...n] : b
          end
          @network.process(inputs, n) || [nil]
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
            wet = @output_groups[index].sum * wet_gain(index)
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
            wet = @pipeline_output.sum * wet_gain(0)
            (wet.inplace + @dry_output.sum).not_inplace!
          end
        end

        # The network's layout as a GraphViz cluster (DOT lines) for
        # Traversable#graphviz when +:show_internals:+ is true (else nil):
        # the inputs feeding each line and their gains, each diffusion stage
        # (delays in ms, polarities, the normalized Hadamard mix and the
        # shuffle), the feedback lines (loop delays in ms, loop gains, the
        # Householder reflection feeding them back, damping if any), and the
        # lines each output sums, drawn from the Layout the network runs
        # (Reverb::Network::Layout), with a dashed edge from this reverb's
        # box (+id+, its DOT node id).  Until omnibus18 (2026-10-30) the
        # option built a third copy of the network out of delay and matrix
        # nodes so graphviz could show them (without modulation or loop
        # processing); the maintainer: "Draw from the network."
        def graphviz_internals(id)
          return nil unless @show_internals

          ms = ->(t) { format('%.1f', t * 1000) }
          num = ->(v) { MB::M.sigfigs(v.to_f, 3).to_s }
          row = ->(label, items) { "#{label}: #{items.join(' ')}" }
          node = ->(name, title, rows, color = '#2266ee') {
            text = [title, *rows].map { |t| t.to_s.gsub(/[{}|<>"]/, '') }.join('|')
            "    #{"#{id}/#{name}".inspect} [label=#{text.inspect}, color=#{color.inspect}];\n" # (fields stack top to bottom: rankdir LR)
          }
          name = ->(n) { "#{id}/#{n}".inspect }

          lines = @layout.lines
          inputs = partition_outputs((0...@upstreams.length).to_a, lines)
          dot = +"  subgraph #{"cluster_#{id}".inspect} {\n"
          dot << "    label=#{"Reverb network: #{lines} lines".inspect}; fontcolor=\"#ffffff\"; color=\"#888888\"; style=\"dashed\";\n"
          dot << node.('inputs', 'inputs to lines', inputs.each_with_index.map { |g, i| "line #{i + 1}: in #{g.map { |x| x + 1 }.join('+')} x #{num.(@input_gains[i])}" })

          chain = ['inputs']
          @layout.diffusion.each_with_index do |st, k|
            dot << node.("diffusion_#{k + 1}", "diffusion #{k + 1}", [
              row.('delays ms', st[:delays].map(&ms)),
              row.('polarity', st[:polarity].map { |v| v < 0 ? '-' : '+' }),
              'Hadamard mix / sqrt(lines)',
              row.('shuffle', st[:order].map { |o| o + 1 }),
            ], '#2288aa')
            chain << "diffusion_#{k + 1}"
          end

          if @layout.taps
            loops = @layout.taps.map { |t| t + @layout.loop_extra }
            rows = loops.each_with_index.map { |t, i| "line #{i + 1}: #{ms.(t)} ms, gain #{num.(@layout.gains[i])}" }
            rows << row.('damping', @layout.damping.map(&num)) if @layout.damping
            dot << node.('feedback', 'feedback lines (loop delay, loop gain)', rows, '#aa4422')
            dot << node.('householder', 'Householder reflection', [row.('order', @layout.order.map { |o| o + 1 })], '#aa4422')
            chain << 'feedback'
            dot << "    #{name.('feedback')} -> #{name.('householder')} [color=red, constraint=false];\n"
            dot << "    #{name.('householder')} -> #{name.('feedback')} [color=red, label=\"feedback\", constraint=false];\n"
          end

          outs = partition_outputs((0...lines).to_a, @output_channels)
          dot << node.('outputs', 'outputs (lines summed)', outs.each_with_index.map { |g, i| "out #{i + 1}: lines #{g.map { |x| x + 1 }.join(' ')} x #{num.(@output_scales[i])}" })
          chain << 'outputs'
          chain.each_cons(2) { |a, b| dot << "    #{name.(a)} -> #{name.(b)};\n" }
          dot << "  }\n"
          dot << "  #{id.inspect} -> #{name.('inputs')} [style=dashed, label=\"inside\", constraint=false];\n"
          dot
        end

        private

        # The kernel's duck amount (dB of reduction, 0 for none) for
        # +duck+: nil or a node (dB of reduction) as is, else
        # Decibels.reduction_db (-12.db and 12.db both duck by 12 dB).
        def duck_db(duck)
          return 0 if duck.nil?
          return duck if duck.is_a?(GraphNode)

          d = Decibels.reduction_db(duck, 'duck')
          d == 0 ? 0 : d
        end

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

        # First-order absorption filters for +damping+.  +design+ :exact
        # (default since 2026-10-10) solves for each line's pole exactly
        # (below); :jot is Jot's design (JOS, PASP, "First-Order
        # Delay-Filter Design"): for each line's loop gain g at DC, the pole
        # p = ln(10) / 4 * log10(g) * (1 - 1 / alpha**2), alpha the reverb
        # time at Nyquist over the reverb time at DC (1 - +damping+, at
        # least 0.05), so high frequencies decay faster by the same factor
        # in every line.  Returns the kernel's one-pole coefficients 1 - p.
        #
        # Jot's pole is a small-pole approximation: it overshoots the
        # damping already at 0.5 (Nyquist RT60 0.4x instead of 0.5x) and,
        # for damping above about 0.7, reaches the 0.999 clamp on the longer
        # lines, whose cutoffs then fall to ~8 Hz, so those lines die within
        # tens of ms at every frequency (2026-10-10, "0.85 barely has any
        # tail").  +design+ :exact instead solves for the pole that gives
        # exactly alpha at Nyquist: g (1 - p) / (1 + p) = g ** (1 / alpha),
        # i.e. r = g ** (1 / alpha - 1), p = (1 - r) / (1 + r) (the
        # filter's DC gain is 1, so DC keeps the line's decay).
        def damping_coefficients(damping, design: :exact)
          damping = damping.to_f
          raise ArgumentError, 'Damping must be between 0.0 and 1.0' unless damping.between?(0, 1)

          alpha = [1.0 - damping, 0.05].max
          case design
          when :jot
            @gains.map { |g|
              p = Math.log(10) / 4 * Math.log10(g.clamp(1e-9, 1.0)) * (1 - 1 / alpha**2)
              1.0 - p.clamp(0.0, 0.999)
            }
          when :exact
            @gains.map { |g|
              r = g.clamp(1e-9, 1.0) ** (1 / alpha - 1)
              p = (1 - r) / (1 + r)
              1.0 - p.clamp(0.0, 0.999)
            }
          else
            raise ArgumentError, "Unknown damping design #{design.inspect} (:jot or :exact)"
          end
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
