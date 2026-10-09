module MB
  module Sound
    module GraphNode
      # Methods that append delays and reverbs to a graph.  Included in
      # GraphNode.
      module DelayMethods
        # Adds a MB::Sound::Filter::Delay to the signal chain with a delay of
        # +time+ (also accepted as +:seconds+): a number of seconds, any
        # length (`5.samples`, `250.ms`, `0.01.seconds`), a musical length
        # that follows the tempo (`3.n16`, `1.n8.dotted`), or a graph node
        # giving the time every sample (seconds, or samples with
        # `node.samples`; musical-time nodes like
        # `2.bars.lfo.square.at(3.n16..5.n16)` follow the tempo).  The time
        # keeps its unit when the sample rate changes: inside #oversample,
        # `5.samples` stays 5 samples at the oversampled rate and `0.01`
        # stays 10 ms.  Buffers for musical lengths are sized for tempos down
        # to Sequence::TempoNode::SLOWEST_BPM; +:max_delay+ (any length)
        # sizes the initial buffer otherwise (buffers grow as needed).
        #
        # See MB::Sound::Filter::Delay#initialize for a description of the
        # +:smoothing+ parameter.  By default, delay time changes (including
        # tempo changes) glide like a tape delay; pass `smoothing: false` to
        # jump instead.
        #
        # The +:feedback+ gain and the +:wet+ and +:dry+ levels may be numbers
        # or graph nodes (e.g. an LFO or a MIDI CC), read every sample.
        #
        # +:interpolation+ chooses how fractional and moving delays are read:
        # :sinc (the default; band-limited, so sweeping delays don't dull
        # high frequencies or alias), :cubic, or :linear (cheapest, and the
        # lo-fi sound of older delays).  See MB::Sound::DelayLine.
        #
        # Examples (bin/sound.rb):
        #     sig.delay(0.25, feedback: -6.db, dry: 1)           # seconds
        #     sig.delay(250.ms, feedback: -6.db, dry: 1)         # the same
        #     sig.delay(1.n8.dotted, feedback: -6.db, dry: 1)    # follows the tempo
        #     sig.delay(96.samples)                              # samples at the running rate
        #     sig.delay(lfo.at(10..20).samples)                  # a node in samples
        #     sig.delay(0.3, feedback: 0.2.hz.lfo.at(0.2..0.8), dry: 1)  # swelling repeats
        #
        # This can be used for spectral distortion:
        #
        #     graph = (60.hz * 0.5.hz.ramp.at(1..0).with_phase(-0.5))
        #       .proc { |v| MB::Sound.real_fft(v) }
        #       .delay(3208.4.samples, feedback: 0.9, dry: 1, wet: 1)
        #       .proc { |v| MB::Sound.real_ifft(MB::M.shl(v, 0)) }
        #
        # With a block, the feedback runs through the block's nodes (an
        # insert, e.g. a tape echo's tone filter and saturation) in a
        # FeedbackLoop: the block gets the delayed signal and returns what the
        # loop outputs and feeds back (times +:feedback+), one sample at a
        # time, so inserts work at any delay length and block size.  The
        # delay absorbs the insert's latency (an antialiased shaper's half
        # sample, a lowpass's group delay), so repeats stay exactly +time+
        # apart.  The output is +:wet+ times the loop plus +:dry+ times the
        # input.  See GraphNode#feedback for what the block may contain.
        #
        #     sig.delay(0.3, feedback: 0.7, dry: 1) { |fb| fb.filter(:lowpass, cutoff: 3000).softclip(0.5, 1) }   # tape echo
        #     sig.delay(lfo.at(1..5).ms, feedback: -0.8, dry: 1) { |fb| fb.softclip }                               # flanger
        #
        # Insert pipelines: when the block calls the builders on its argument
        # (see InsertPipeline), `d.fb { |fb| ... }` processes only the
        # recirculated signal (in the loop: the first echo is clean, every
        # later repeat is processed once more), and `d.wet { |wet| ... }`
        # processes every echo on its way out without feeding it back
        # (outside the loop).  Either may be left out.
        #
        #     sig.delay(0.3, feedback: 0.7, dry: 1) { |d|
        #       d.fb { |fb| fb.filter(3000.hz.lowpass).softclip }    # repeats get darker and dirtier
        #       d.wet { |wet| wet.filter(5000.hz.lowpass) }          # every echo, once
        #     }
        #
        # With d.fb the echoes come from a second delay line outside the
        # loop (the loop's own delay reads early by the insert's latency),
        # so pipeline delays cost about one more delay.
        def delay(time = nil, seconds: nil, smoothing: true, max_delay: 1.0, feedback: false, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, &insert)
          if insert
            return feedback_delay(
              time, seconds: seconds, smoothing: smoothing, max_delay: max_delay, feedback: feedback,
              dry: dry, wet: wet, interpolation: interpolation, &insert
            )
          end

          filter(MB::Sound::GraphNode::DelayMethods.delay_filter(
            time, seconds: seconds, smoothing: smoothing, max_delay: max_delay,
            feedback: feedback, dry: dry, wet: wet, interpolation: interpolation
          ))
        end

        # #delay with a feedback insert block (see #delay).
        def feedback_delay(time = nil, seconds: nil, smoothing: true, max_delay: 1.0, feedback: false, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, &insert)
          if feedback.nil? || feedback == false
            raise ArgumentError, 'A delay with a feedback insert block needs a feedback: gain (a number or a node)'
          end

          delay_opts = { seconds: seconds, smoothing: smoothing, max_delay: max_delay, interpolation: interpolation }
          pipeline = nil

          # (echo loops: no sustain shelf, whose pitch would be 1 / time)
          loop = self.feedback(sustain: false) do |fb, input|
            delayed = (input + fb * feedback).delay(time, **delay_opts)
            pipeline = InsertPipeline.new(delayed)
            out = pipeline.call(insert)
            raise ArgumentError, "The delay's insert block must return a graph node (got #{out.inspect})" unless out.respond_to?(:sample)

            out
          end

          echoes = loop
          if pipeline.pipeline? && pipeline.fb_insert
            # The loop outputs the processed repeats; the echoes on their
            # way out are the delay line's own output (first echo clean),
            # rebuilt outside the loop from the same input and repeats
            echoes = (self + loop * feedback).delay(time, **delay_opts)
          end
          echoes = pipeline.apply_wet(echoes) if pipeline.pipeline?

          out = wet.is_a?(Numeric) && wet == 1 ? echoes : echoes * wet
          out = out + self * dry unless dry.is_a?(Numeric) && dry == 0
          out
        end

        # The argument of #delay's insert block: the delayed signal (a graph
        # node, for tape-style inserts that return the processed signal),
        # with two pipeline builders while the block runs:
        #
        # - `d.fb { |fb| ... }` processes only the recirculated signal (the
        #   repeats from the second on are processed, the first echo is
        #   clean); it runs in the loop, one sample at a time.
        # - `d.wet { |wet| ... }` processes every echo on its way to the
        #   output and isn't fed back (a feed-forward chain outside the
        #   loop, run a block at a time).
        #
        # A block that calls either builder is a pipeline (its return value
        # is ignored); any other block returns the tape-style insert.
        class InsertPipeline
          attr_reader :fb_insert, :wet_insert

          def initialize(delayed)
            @delayed = delayed
            @pipeline = false
            @fb_insert = nil
            @wet_insert = nil
          end

          # True if the block called d.fb or d.wet.
          def pipeline?
            @pipeline
          end

          # Calls the user's insert block with the delayed signal and the
          # builders attached, and returns the loop's output node.
          def call(block)
            pipe = self
            d = @delayed
            d.define_singleton_method(:fb) do |&b|
              raise ArgumentError, 'd.fb takes a block that processes the recirculated signal' unless b

              pipe.send(:set_fb, b)
            end
            d.define_singleton_method(:wet) do |&b|
              raise ArgumentError, 'd.wet takes a block that processes the echoes on their way out' unless b

              pipe.send(:set_wet, b)
            end

            begin
              ret = block.call(d)
            ensure
              d.singleton_class.send(:remove_method, :fb)
              d.singleton_class.send(:remove_method, :wet)
            end

            return ret unless @pipeline

            @fb_insert || d
          end

          # Runs the wet block on +echoes+ (outside the loop).
          def apply_wet(echoes)
            return echoes unless @wet_block

            out = @wet_block.call(echoes)
            raise ArgumentError, "d.wet's block must return a graph node (got #{out.inspect})" unless out.respond_to?(:sample)

            @wet_insert = out
          end

          private

          def set_fb(b)
            raise ArgumentError, 'd.fb may only be given once' if @fb_insert

            @pipeline = true
            out = b.call(@delayed)
            raise ArgumentError, "d.fb's block must return a graph node (got #{out.inspect})" unless out.respond_to?(:sample)

            @fb_insert = out
            self
          end

          def set_wet(b)
            raise ArgumentError, 'd.wet may only be given once' if @wet_block

            @pipeline = true
            @wet_block = b
            self
          end
        end

        # Builds the MB::Sound::Filter::Delay for #delay and
        # Sequence::Duration#delay (see #delay for parameters).
        def self.delay_filter(time = nil, seconds: nil, smoothing: true, max_delay: 1.0, feedback: false, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION)
          raise ArgumentError, 'Pass a delay time or seconds:, not more than one' if time && seconds
          time ||= seconds || 0

          MB::Sound::Filter::Delay.new(
            delay: time, smoothing: smoothing,
            delay_buffer_size: MB::Sound::Length.samples(max_delay, sample_rate: 48000).ceil, feedback: feedback,
            dry: dry, wet: wet, interpolation: interpolation
          )
        end

        # Adds a multi-tap delay with the given delay sources, returning an Array
        # of nodes representing the taps, as a channel bundle (e.g.
        # `l, r = sig.multitap(...)`).  Also available as #multitap_delay.
        # The +delays+ may be any delay time accepted by #delay: seconds,
        # lengths (`96.samples`, `250.ms`), musical lengths that follow the
        # tempo (`1.n8.dotted`), or graph nodes.
        #
        # Delay changes jump unless +:smoothing+ is given (true, a rate in
        # seconds per second, or a Filter, as for #delay), which glides each
        # tap's delay like a tape delay.  +:initial_buffer+ (any length) sizes
        # the starting buffer (it grows as needed).
        #
        # +:interpolation+ is as for #delay.
        #
        # Example (bin/sound.rb):
        #     l, r = sig.multitap(1.n8.dotted, 1.n4)
        def multitap(*delays, name: nil, initial_buffer: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, smoothing: false)
          MB::Sound::GraphNode::MultitapDelay.new(
            self,
            *delays,
            initial_buffer: initial_buffer,
            interpolation: interpolation,
            smoothing: smoothing
          ).named(name).taps.then { |taps| Channels.new(taps) }
        end
        alias multitap_delay multitap

        # Appends a reverb to this node (see GraphNode::Reverb).  Named presets
        # change default parameters, but you can override any of the preset's
        # parameters.
        #
        # If this is a multi-output node (e.g. a splittable input object), then
        # the outputs are broken out as a multichannel input to the Reverb.
        #
        # Presets: :room, :hall, :stadium, :space, :default (the classic
        # presets, as they sounded in 2026-01), plus the room-size presets
        # :plate, :shimmer, :grit, :lofi, :gated, :drone.  See Reverb::PRESETS.
        #
        # The friendly form: without a preset, +:room_size:+ (0..1),
        # +:decay:+ (the reverb time, RT60, in seconds or any Length), and
        # +:damping:+ (0..1, how much faster highs decay) build a reverb
        # from a room-size layout (see Reverb::ROOM_DEFAULTS), with subtle
        # delay modulation on.  +:predelay:+, +:mix:+ (0..1) or +:wet:+ and
        # +:dry:+, and every option below work with it too.
        #
        # Options (see MB::Sound::GraphNode::Reverb#initialize for details):
        # - layout: +:channels:+, +:stages:+, +:diffusion_range:+,
        #   +:feedback_range:+, +:feedback_gain:+ or +:decay:+, +:seed:+,
        #   +:loop_extra:+, +:feedback_enabled:+, +:predelay:+
        # - mix: +:wet:+, +:dry:+, +:mix:+, +:extra_time:+ (silence added to
        #   inputs so the tail rings out)
        # - modulation: +:modulation:+ (alias +:mod:+; feedback lines) and
        #   +:diffusion_modulation:+ (alias +:diffusion_mod:+): true, a
        #   preset name (:subtle, :lush, :chorus, :seasick), a depth, or a
        #   Hash of +:depth:+, +:rate:+, +:shape:+, +:spread:+
        # - in the feedback loop: +:damping:+ or +:lowpass:+, +:highpass:+,
        #   +:drive:+ (+:drive_mode:+), +:crush:+, +:shimmer:+
        #   (+:shimmer_pitch:+), +:freeze:+, +:stretch:+ (most may be nodes)
        #
        # If +:output_channels+ is greater than one, then this method returns a
        # channel bundle (GraphNode::Channels).  Otherwise it returns a single
        # output node.  Channel bundles have their own #reverb, which takes
        # every channel as a reverb input.
        #
        # Example (bin/sound.rb):
        #     play file_input('sounds/drums.flac').reverb
        #     play file_input('sounds/piano0.flac').reverb(:space)
        #     play file_input('sounds/piano0.flac').reverb(room_size: 0.8, decay: 4, damping: 0.6, output_channels: 2)
        #     play file_input('sounds/piano0.flac').reverb(:hall, mod: :lush, shimmer: 0.4, output_channels: 2)
        def reverb(preset = nil, output_channels: 1, **options)
          MB::Sound::GraphNode::Reverb.reverb(preset, input: self, output_channels: output_channels, **options)
        end
      end
    end
  end
end
