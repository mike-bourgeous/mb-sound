module MB
  module Sound
    module GraphNode
      # Methods that append delays and reverbs to a graph.  Included in
      # GraphNode.
      module DelayMethods
        # Adds a MB::Sound::Filter::Delay to the signal chain with a delay of
        # +time+: a number of seconds, any
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
        # +:smooth+ glides delay time changes (including tempo changes) like
        # a tape delay: true (the default), a rate in seconds per second, or
        # a Filter (see the +:smoothing+ parameter of
        # MB::Sound::Filter::Delay#initialize); pass `smooth: false` to jump
        # instead.  (+:smoothing+ is accepted too.)
        #
        # +:seconds+ (the old spelling of +time+) is deprecated: it warns
        # once per call site (graph documents still load it silently).
        #
        # The +:feedback+ gain and the +:wet+ and +:dry+ levels may be numbers
        # or graph nodes (e.g. an LFO or a MIDI CC), read every sample.
        #
        # +:interpolation+ chooses how fractional and moving delays are read:
        # :sinc (the default; band-limited, so sweeping delays don't dull
        # high frequencies or alias), :cubic, or :linear (cheapest, and the
        # lo-fi sound of older delays).  See MB::Sound::DelayLine.
        #
        # When the input ends, the delay rings out: its last echo plays, and
        # with feedback the repeats go on until they fall below -90 dB (see
        # MB::Sound::QuietRun#advance); then the delay ends.  Pass `ring_out: false`
        # to end with the input instead (e.g. inside a structure with its own
        # tail handling, like Reverb's extra_time).
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
        #     graph = (60.hz * 0.5.hz.saw.at(1..0).with_phase(-0.5))
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
        def delay(time = nil, seconds: nil, smooth: nil, smoothing: nil, max_delay: 1.0, feedback: false, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, ring_out: true, &insert)
          time = DelayMethods.seconds_keyword(time, seconds)
          DelayMethods.check_plain_time(time)
          smoothing = DelayMethods.smooth_keyword(smooth, smoothing, true)

          if insert
            raise ArgumentError, "ring_out: false isn't supported with an insert block (the feedback loop rings out)" unless ring_out

            return feedback_delay(
              time, smooth: smoothing, max_delay: max_delay, feedback: feedback,
              dry: dry, wet: wet, interpolation: interpolation, &insert
            )
          end

          if DelayMethods.feedback?(feedback)
            # The feedback-loop engine (fast_loop), with nothing in the loop
            # but the gain: the samples Filter::Delay's own feedback kernel
            # gave, about 40% cheaper (smoothing-1)
            raise ArgumentError, "ring_out: false isn't supported with feedback: (the feedback loop rings out)" unless ring_out

            return feedback_delay(
              time, smooth: smoothing, max_delay: max_delay, feedback: feedback,
              dry: dry, wet: wet, interpolation: interpolation
            ) { |d| d }
          end

          filter(MB::Sound::GraphNode::DelayMethods.delay_filter(
            time, smooth: smoothing, max_delay: max_delay,
            dry: dry, wet: wet, interpolation: interpolation, ring_out: ring_out
          ))
        end

        # True if +v+ is a plain real level (a number, Decibels included).
        def self.level?(v)
          v.is_a?(Numeric) && v.real?
        end

        # True if +feedback+ (#delay's feedback: gain) makes a feedback loop:
        # a node, or a nonzero real number (complex gains raise: feedback
        # loops are real; false, nil, and 0 are a plain delay).
        def self.feedback?(feedback)
          return false if feedback.nil? || feedback == false
          if feedback.is_a?(Numeric)
            raise ArgumentError, "Delay feedback gains must be real (got #{feedback.inspect}); feedback loops are real (a complex signal's parts loop separately)" unless feedback.real?

            return feedback != 0
          end
          raise ArgumentError, "Delay feedback is a number or a graph node (got #{feedback.inspect})" unless feedback.respond_to?(:sample)

          true
        end

        # #delay with a feedback insert block (see #delay).
        def feedback_delay(time = nil, seconds: nil, smooth: nil, smoothing: nil, max_delay: 1.0, feedback: false, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, &insert)
          time = DelayMethods.seconds_keyword(time, seconds)
          smoothing = DelayMethods.smooth_keyword(smooth, smoothing, true)

          if feedback.nil? || feedback == false
            raise ArgumentError, 'A delay with a feedback insert block needs a feedback: gain (a number or a node)'
          end

          delay_opts = { smooth: smoothing, max_delay: max_delay, interpolation: interpolation }
          pipeline = nil

          # (echo loops: no sustain shelf, whose pitch would be 1 / time,
          # and the echo compensation, where low cuts count as wires; see
          # Plan::Loop::Program::ECHO_WIRES)
          bare = false
          loop = self.feedback(sustain: false, compensate: :echo) do |fb, input|
            delayed = (input + fb * feedback).delay(time, **delay_opts)
            pipeline = InsertPipeline.new(delayed)
            out = pipeline.call(insert)
            raise ArgumentError, "The delay's insert block must return a graph node (got #{out.inspect})" unless out.respond_to?(:sample)

            bare = out.equal?(delayed)
            out
          end
          # Nothing but the gain and the sum around the delay: no latency to
          # compensate (the same samples, measured over constant, negative,
          # and sign-changing gains and moving times), so the loop skips the
          # per-block pitch tracking (smoothing-1)
          loop.skip_compensation! if bare

          echoes = loop
          if pipeline.pipeline? && pipeline.fb_insert
            # The loop outputs the processed repeats; the echoes on their
            # way out are the delay line's own output (first echo clean),
            # rebuilt outside the loop from the same input and repeats
            echoes = DelayMethods.ring_sum(self, loop * feedback).delay(time, **delay_opts)
          end
          echoes = pipeline.apply_wet(echoes) if pipeline.pipeline?

          # Numeric levels on the loop itself: mixed in C after each block
          # (FeedbackLoop#output_mix), without a Tee and a Mixer
          if echoes.equal?(loop) && DelayMethods.level?(wet) && DelayMethods.level?(dry) && loop.output_mix(wet, dry)
            return loop
          end

          out = wet.is_a?(Numeric) && wet == 1 ? echoes : echoes * wet
          out = DelayMethods.ring_sum(out, self * dry) unless dry.is_a?(Numeric) && dry == 0
          out
        end

        # The feedback gains of #multitap's +count+ taps for +feedback+ (see
        # #multitap): an Array as given, one gain shared evenly.
        def self.tap_gains(feedback, count)
          if feedback.is_a?(Array)
            raise ArgumentError, "multitap feedback: needs one gain per tap (#{count}; got #{feedback.length})" unless feedback.length == count
            return feedback
          end
          if feedback.is_a?(Numeric)
            raise ArgumentError, "multitap feedback: must be real (got #{feedback.inspect})" unless feedback.real?
            return Array.new(count, feedback.to_f / count)
          end
          raise ArgumentError, "multitap feedback: is a number, a node, or an Array of them (got #{feedback.inspect})" unless feedback.respond_to?(:sample)

          g = count == 1 ? feedback : feedback * (1.0 / count)
          Array.new(count, g)
        end

        # The sum of +a+ and +b+ that plays on until both end (a Mixer with
        # stop_early: false), so a delay's echoes ring out after its input
        # (and the dry signal) ends.
        def self.ring_sum(a, b)
          Mixer.new([a, b], sample_rate: a.sample_rate, stop_early: false)
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

        # The delay time from #delay's +time+ and its deprecated +:seconds+
        # keyword (maintainer decision 2026-10-13; research-api-surface
        # R2): +seconds+ warns once per call site (the first caller outside
        # this library), except inside .quiet_seconds (graph documents keep
        # loading `seconds:` silently).
        def self.seconds_keyword(time, seconds)
          return time if seconds.nil?
          raise ArgumentError, 'Pass a delay time or seconds:, not more than one' if time
          return seconds if Thread.current[:mb_sound_quiet_seconds]

          Internal.warn_once_per_site(:delay_seconds, 'delay(seconds: t) is deprecated; write delay(t) (seconds, or any length like 250.ms)')
          seconds
        end

        # Plain numbers longer than this are probably meant as samples or
        # milliseconds (see .check_plain_time).
        LONG_PLAIN_SECONDS = 10

        # Warns once per calling line for a plain-number delay time over
        # LONG_PLAIN_SECONDS (ux-fix-1, maintainer decision 2026-10-18:
        # plain numbers stay seconds, but `delay(96)` was a 96-second delay
        # line, silently).
        def self.check_plain_time(time)
          return unless [Integer, Float, Rational].include?(time.class) && time > LONG_PLAIN_SECONDS

          Internal.warn_once_per_site(:delay_long, "delay(#{time}) is #{time} seconds (plain numbers are seconds); for samples write delay(#{time}.samples), for milliseconds delay(#{time}.ms)")
        end

        # Runs the block without .seconds_keyword's deprecation warning
        # (for graph document loading).
        def self.quiet_seconds(&block)
          Internal.with_local(:mb_sound_quiet_seconds, true, &block)
        end

        # The delay smoothing from +:smooth+ and its older spelling
        # +:smoothing+ (research-api-surface R3), or +default+.
        def self.smooth_keyword(smooth, smoothing, default)
          raise ArgumentError, 'Pass smooth: or smoothing: (the same option), not both' unless smooth.nil? || smoothing.nil?
          return smooth unless smooth.nil?
          return smoothing unless smoothing.nil?
          default
        end

        # Builds the MB::Sound::Filter::Delay for #delay and
        # Sequence::Duration#delay (see #delay for parameters; feedback is
        # #delay's, a FeedbackLoop around the delay).
        def self.delay_filter(time = nil, seconds: nil, smooth: nil, smoothing: nil, max_delay: 1.0, dry: 0, wet: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, ring_out: true)
          time = seconds_keyword(time, seconds) || 0
          smoothing = smooth_keyword(smooth, smoothing, true)

          MB::Sound::Filter::Delay.new(
            delay: time, smoothing: smoothing,
            delay_buffer_size: MB::Sound::Length.samples(max_delay, sample_rate: 48000).ceil,
            dry: dry, wet: wet, interpolation: interpolation, ring_out: ring_out
          )
        end

        # Adds a multi-tap delay with the given delay sources, returning an Array
        # of nodes representing the taps, as a channel bundle (e.g.
        # `l, r = sig.multitap(...)`).  Also available as #multitap_delay.
        # The +delays+ may be any delay time accepted by #delay: seconds,
        # lengths (`96.samples`, `250.ms`), musical lengths that follow the
        # tempo (`1.n8.dotted`), or graph nodes.
        #
        # Delay changes jump unless +:smooth+ is given (true, a rate in
        # seconds per second, or a Filter, as for #delay; +:smoothing+ is
        # accepted too), which glides each
        # tap's delay like a tape delay.  +:initial_buffer+ (any length) sizes
        # the starting buffer (it grows as needed).
        #
        # +:interpolation+ is as for #delay.
        #
        # +:feedback+ makes the taps regenerate (a GraphNode::DelayNetwork
        # with one line, run per sample in C): an Array of one gain per tap
        # (numbers or nodes; 0 or nil for a tap that isn't fed back), or one
        # gain (a number or node) for the loop as a whole, shared evenly by
        # the taps (each tap feeds back gain / taps, so any gain below 1
        # decays however many taps there are).  The line gets the input plus
        # every gain times its tap, so the echoes multiply like a tape echo
        # with several playback heads.  Without +:feedback+ the taps are a
        # plain MultitapDelay, as before.
        #
        # Example (bin/sound.rb):
        #     l, r = sig.multitap(1.n8.dotted, 1.n4)
        #     a, b, c = sig.multitap(1.n8, 3.n16, 1.n4, feedback: [0.3, 0, 0.25])   # regenerating heads
        #     sig.multitap(150.ms, 400.ms, feedback: 0.6).to_a.sum                # one intensity knob
        def multitap(*delays, name: nil, initial_buffer: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, smooth: nil, smoothing: nil, feedback: nil)
          smoothing = DelayMethods.smooth_keyword(smooth, smoothing, false)
          unless feedback.nil? || feedback == false
            raise ArgumentError, 'No delay taps were provided; give delay times (seconds, lengths, Durations, or graph nodes)' if delays.empty?

            return MB::Sound::GraphNode::DelayNetwork.new(
              inputs: [self],
              taps: delays.map { |d| [0, d] },
              gains: [DelayMethods.tap_gains(feedback, delays.length)],
              initial_buffer: initial_buffer, interpolation: interpolation, smoothing: smoothing
            ).named(name).taps.then { |taps| Channels.new(taps) }
          end

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
        # presets, as they sounded in 2026-01, except :room's wet now at 0 dB
        # and :hall's compact loops, 2026-10-10), plus the room-size presets
        # :plate, :shimmer, :grit, :lofi, :gated, :drone.  See Reverb.presets.
        #
        # The friendly form: without a preset, +:room_size:+ (0..1),
        # +:decay:+ (the reverb time, RT60, in seconds or any Length), and
        # +:damping:+ (0..1: the reverb time at Nyquist is 1 - damping times
        # the reverb time; default 0.6) build a reverb
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
        # - in the feedback loop: +:damping:+ (+:damping_design:+) or
        #   +:lowpass:+, +:highpass:+, +:drive:+ (+:drive_mode:+), +:crush:+,
        #   +:shimmer:+ (+:shimmer_pitch:+), +:freeze:+, +:stretch:+
        # - after the network: +:duck:+, +:gate:+, +:threshold:+
        #
        # Live parameters (numbers or nodes, read every sample, so a bound
        # knob turns them without a rebuild): +:mix:+, +:wet:+, +:dry:+,
        # +:level:+ (gains after the network; delays-2), +:predelay:+ (a
        # node glides the read position at #delay's slew limit),
        # +:lowpass:+, +:highpass:+, +:drive:+, +:crush:+, +:shimmer:+,
        # +:freeze:+, +:stretch:+, +:duck:+, +:gate:+, +:threshold:+, and the
        # modulation depths and rates.  Fixed when built: +:room_size:+,
        # +:decay:+, +:damping:+, +:shimmer_pitch:+, and the layout.
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
