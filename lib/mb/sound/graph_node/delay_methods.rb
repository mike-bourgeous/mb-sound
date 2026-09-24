module MB
  module Sound
    module GraphNode
      # Methods that append delays and reverbs to a graph.  Included in
      # GraphNode.
      module DelayMethods
        # Adds a MB::Sound::Filter::Delay to the signal chain with a delay of the
        # given number of +:seconds+ or +:samples+.
        #
        # See MB::Sound::Filter::Delay#initialize for a description of the
        # +:smoothing+ parameter.
        #
        # This can be used for spectral distortion:
        #
        #     graph = (60.hz * 0.5.hz.ramp.at(1..0).with_phase(-Math::PI))
        #       .proc { |v| MB::Sound.real_fft(v) }
        #       .delay(samples: 3208.4, feedback: 0.9, dry: 1, wet: 1)
        #       .proc { |v| MB::Sound.real_ifft(MB::M.shl(v, 0)) }
        def delay(seconds: nil, samples: nil, sample_rate: 48000, smoothing: true, max_delay: 1.0, feedback: false, dry: 0, wet: 1)
          if samples
            samples = samples.to_f if samples.is_a?(Numeric)
            seconds = samples / sample_rate
          else
            seconds = seconds.to_f if seconds.is_a?(Numeric)
          end

          seconds = seconds.or_for(nil) if seconds.respond_to?(:or_for)

          filter(MB::Sound::Filter::Delay.new(
            delay: seconds, sample_rate: sample_rate, smoothing: smoothing,
            delay_buffer_size: sample_rate.ceil * max_delay, feedback: feedback,
            dry: dry, wet: wet
          ))
        end

        # Adds a multi-tap delay with the given delay sources, returning an Array
        # of nodes representing the taps.  The +delays+ may be numeric values in
        # seconds, or graph nodes that produce a number of seconds as output.
        #
        # To smooth delay values, use #clip_rate, #smooth, #filter, or similar
        # methods (unlike the filter used by #delay, the
        # MB::Sound::GraphNode::MultitapDelay does not do built-in smoothing).
        def multitap(*delays, sample_rate: 48000, name: nil, initial_buffer_seconds: 1)
          MB::Sound::GraphNode::MultitapDelay.new(
            self,
            *delays,
            sample_rate: sample_rate,
            initial_buffer_seconds: initial_buffer_seconds
          ).named(name).taps
        end

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
        # If +:output_channels+ is greater than one, then this method returns an
        # Array of output nodes.  Otherwise it returns a single output node.
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
        #     play 440.hz.sine.for(0.5).fdn_reverb(room_size: 0.8, decay: 3.0)
        #
        #     # Stereo file input -> stereo reverb
        #     play file_input('sounds/synth0.flac').fdn_reverb
        def fdn_reverb(room_size: 0.5, decay: 2.0, damping: 0.5, diffusion_steps: 4, channels: 8, output_channels: nil, wet: 0.3, dry: 0.7, seed: 0, sample_rate: 48000, tail: nil)
          tail = decay + 0.5 if tail.nil?
          tail = 0 if tail == false

          input = if self.is_a?(MultiOutput)
            self.outputs.map { |out|
              node = out.get_sampler
              tail > 0 ? node.and_then(0.constant.for(tail)) : node
            }
          else
            tail > 0 ? self.and_then(0.constant.for(tail)) : self
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
