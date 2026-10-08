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
        #     graph = (60.hz * 0.5.hz.ramp.at(1..0).with_phase(-Math::PI))
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

          loop = self.feedback do |w, x|
            delayed = (x + w * feedback).delay(time, seconds: seconds, smoothing: smoothing, max_delay: max_delay, interpolation: interpolation)
            out = insert.call(delayed)
            raise ArgumentError, "The delay's insert block must return a graph node (got #{out.inspect})" unless out.respond_to?(:sample)

            out
          end

          out = wet.is_a?(Numeric) && wet == 1 ? loop : loop * wet
          out = out + self * dry unless dry.is_a?(Numeric) && dry == 0
          out
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

        # Appends a reverb to this node.  Named presets change default
        # parameters, but you can override any of the preset's parameters.
        #
        # If this is a multi-output node (e.g. a splittable input object), then
        # the outputs are broken out as a multichannel input to the Reverb.
        #
        # Presets: :room, :hall, :stadium, :space, :default.  See
        # Reverb::PRESETS.
        #
        # See MB::Sound::GraphNode::Reverb#initialize for parameter descriptions.
        #
        # The +:extra_time+ parameter controls how much time to add to input
        # objects to allow the reverb to decay.
        #
        # If +:output_channels+ is greater than one, then this method returns a
        # channel bundle (GraphNode::Channels).  Otherwise it returns a single
        # output node.  Channel bundles have their own #reverb, which takes
        # every channel as a reverb input.
        #
        # Example (bin/sound.rb):
        #     play file_input('sounds/drums.flac').reverb
        #     play file_input('sounds/piano0.flac').reverb(:space)
        def reverb(preset = :default, extra_time: nil, output_channels: 1, channels: nil, stages: nil, diffusion_range: nil, feedback_range: nil, feedback_gain: nil, feedback_enabled: nil, predelay: nil, wet: nil, dry: nil, seed: nil, show_internals: false)
          MB::Sound::GraphNode::Reverb.reverb(
            preset,
            input: self,
            extra_time: extra_time,
            output_channels: output_channels,
            channels: channels,
            stages: stages,
            diffusion_range: diffusion_range,
            feedback_range: feedback_range,
            feedback_gain: feedback_gain,
            feedback_enabled: feedback_enabled,
            predelay: predelay,
            wet: wet,
            dry: dry,
            seed: seed,
            show_internals: show_internals
          )
        end

        # Adds a reverb effect to this node using diffusion stages and a
        # feedback delay network.  See GraphNode::FdnReverb for details.
        #
        # When called on a MultiOutput node (e.g. from InputChannelSplit),
        # the individual outputs are automatically used as separate input
        # channels to the reverb.
        #
        # When +tail+ is given (in seconds), the reverb continues processing
        # silence after the inputs end, allowing the reverb tail to decay.
        # Defaults to +decay + 0.5+.  Set +tail: 0+ or +tail: false+ to
        # disable.
        #
        # Example:
        #     play 440.hz.sine.adsr(0.005, 0.05, 1, 0.05, hold: 0.5).fdn_reverb(room_size: 0.8, decay: 3.0)
        #
        #     # Stereo file input -> stereo reverb
        #     play file_input('sounds/synth0.flac').fdn_reverb
        def fdn_reverb(room_size: 0.5, decay: 2.0, damping: 0.5, diffusion_steps: 4, channels: 8, output_channels: nil, wet: 0.3, dry: 0.7, seed: 0, sample_rate: self.sample_rate, tail: nil)
          decay = MB::Sound::Length.seconds(decay, sample_rate: sample_rate)
          tail = decay + 0.5 if tail.nil?
          tail = 0 if tail == false
          tail = MB::Sound::Length.seconds(tail, sample_rate: sample_rate)

          input = if channel_count > 1
            self.outputs.map { |out|
              node = out.get_sampler
              tail > 0 ? node.and_then(MB::Sound.silence(tail)) : node
            }
          else
            tail > 0 ? self.and_then(MB::Sound.silence(tail)) : self
          end

          MB::Sound::GraphNode::FdnReverb.new(
            input,
            room_size: room_size,
            decay: decay,
            damping: damping,
            diffusion_steps: diffusion_steps,
            channels: channels,
            output_channels: output_channels,
            wet: wet,
            dry: dry,
            seed: seed,
            sample_rate: sample_rate
          )
        end
      end
    end
  end
end
