module MB
  module Sound
    module GraphNode
      class Reverb
        # The diffusion stages and feedback delay network of a Reverb, run
        # one sample at a time in C (MB::Sound::FastReverb::Network; exact
        # Ruby mirror RubyKernel, used when MB_SOUND_REVERB=ruby or
        # +ruby: true+).  Built from a Layout (delays, polarities, shuffles,
        # gains) and live parameters (numbers or GraphNodes, sampled once per
        # block and read per sample by the kernel).
        class Network
          # LFO shapes for the modulation (see the kernel's enum rev_shape).
          SHAPES = {
            sine: 0,
            triangle: 1,
            random: 2,
            smooth: 3,
            smooth_random: 3,
            wander: 3,
          }.freeze

          # Saturation shapes for +drive:+ (see enum rev_drive).
          DRIVE_MODES = {
            soft: 0,
            tanh: 0,
            hard: 1,
            clip: 1,
            fold: 2,
          }.freeze

          # Live parameters in kernel order: [name, unit], where :seconds
          # values are converted to samples at the running rate.
          PARAMS = [
            [:diffusion_depth, :seconds],
            [:diffusion_rate, :hz],
            [:depth, :seconds],
            [:rate, :hz],
            [:lowpass, :hz],
            [:highpass, :hz],
            [:drive, :plain],
            [:shimmer, :plain],
            [:shimmer_ratio, :plain],
            [:freeze, :plain],
            [:stretch, :plain],
            [:crush, :plain],
            [:duck, :plain],
            [:gate, :plain],
            [:threshold, :plain],
          ].freeze

          # The delays, gains, and mixing of a reverb network, all in
          # seconds or plain numbers so a new sample rate rebuilds the same
          # network.
          #
          # +:diffusion+ - an Array of stages, each a Hash with :delays
          #                (seconds per line), :polarity (+1/-1 per line),
          #                :order (the shuffle: stage output k is matrix
          #                output order[k]).
          # +:taps+ - FDN output tap delays (seconds per line), or nil for no
          #           feedback network.
          # +:loop_extra+ - seconds added to each loop beyond its tap.
          # +:gains+ - loop gain per line.
          # +:normal+ - unit normal of the Householder reflection.
          # +:order+ - FDN shuffle (line i's input is reflection output
          #            order[i]).
          # +:input_gains+ - gain per line for the inputs.
          # +:damping+ - per-line one-pole lowpass coefficients (from
          #              Reverb#damping_coefficients) or nil.
          Layout = Struct.new(:lines, :diffusion, :taps, :loop_extra, :gains, :normal, :order, :input_gains, :damping, keyword_init: true)

          # Modulation settings for one stage group: +:shape+ (a SHAPES
          # key), per-line rate multipliers and start phases.
          Modulation = Struct.new(:shape, :rate_scales, :phases, :max_depth, keyword_init: true)

          attr_reader :layout, :sample_rate

          # +layout+ - a Layout.
          # +params+ - a Hash of PARAMS names to numbers or GraphNodes.
          # +diffusion_mod+, +feedback_mod+ - Modulation settings or nil.
          # +drive_mode+ - a DRIVE_MODES key.
          # +shimmer_window+ - the shimmer's grain length in seconds.
          # +max_stretch+ - the largest +:stretch+ the lines are sized for.
          # +seed+ - seeds the random LFO targets.
          # +dynamics+ - true to run the ducking and gate stage (+:duck:+,
          #              +:gate:+, +:threshold:+).
          def initialize(layout:, params:, sample_rate:, diffusion_mod: nil, feedback_mod: nil, drive_mode: :soft, shimmer_window: 0.05, max_stretch: 1, seed: 0, dynamics: false, ruby: ENV['MB_SOUND_REVERB'] == 'ruby')
            @layout = layout
            @diffusion_mod = diffusion_mod
            @feedback_mod = feedback_mod
            @drive_mode = DRIVE_MODES.fetch(drive_mode) { raise ArgumentError, "Unknown drive mode #{drive_mode.inspect} (#{DRIVE_MODES.keys.join(', ')})" }
            @shimmer_window = shimmer_window
            @max_stretch = max_stretch.to_f
            @seed = seed
            @dynamics = dynamics
            @ruby = ruby

            @params = PARAMS.map { |name, _| params[name] }
            @samplers = @params.map { |p| p.is_a?(GraphNode) ? p.get_sampler : p }
            @outputs = []

            self.sample_rate = sample_rate
          end

          # Live parameters that are GraphNodes, for graph traversal.
          def sources
            PARAMS.each_with_index.map { |(name, _), idx| [name, @samplers[idx]] }.select { |_, v| v.is_a?(GraphNode) }.to_h
          end

          # Rebuilds the kernel at +rate+ (the network starts silent).
          def sample_rate=(rate)
            @sample_rate = rate.to_f
            @samplers.each do |s|
              s.sample_rate = @sample_rate if s.respond_to?(:sample_rate=) && s.respond_to?(:sample_rate) && s.sample_rate != @sample_rate
            end
            @kernel_config = kernel_config
            @kernel = (@ruby ? RubyKernel : MB::Sound::FastReverb::Network).new(@kernel_config)
          end

          # The kernel's config Hash (see fast_reverb.c).
          def kernel_config
            rate = @sample_rate
            n = @layout.lines
            stages = @layout.diffusion
            dmod = @diffusion_mod
            fmod = @feedback_mod
            dmax = dmod ? dmod.max_depth * rate : 0
            fmax = fmod ? fmod.max_depth * rate : 0
            taps = @layout.taps ? @layout.taps.map { |s| (s * rate).round } : Array.new(n, 0)
            extra = (@layout.loop_extra * rate).round
            loops = taps.map { |t| t + extra }
            window = (@shimmer_window * rate).round.clamp(4, nil)

            {
              lines: n,
              stages: stages.length,
              sample_rate: rate,
              feedback: !@layout.taps.nil?,
              seed: @seed & 0xFFFF_FFFF_FFFF_FFFF,
              diff_scale: 1.0 / Math.sqrt(n),
              diff_mod: !dmod.nil?,
              fdn_mod: !fmod.nil?,
              diff_shape: dmod ? SHAPES.fetch(dmod.shape) : 0,
              fdn_shape: fmod ? SHAPES.fetch(fmod.shape) : 0,
              drive_mode: @drive_mode,
              shimmer_window: window,
              in_gain: @layout.input_gains,
              diff_delay: stages.flat_map { |st| st[:delays].map { |s| (s * rate).round.to_f } },
              diff_polarity: stages.flat_map { |st| st[:polarity].map(&:to_f) },
              diff_order: stages.flat_map { |st| st[:order] },
              diff_capacity: stages.flat_map { |st| st[:delays].map { |s| (s * rate).round + 2 * dmax + 8 } },
              tap: taps.map(&:to_f),
              loop: loops.map(&:to_f),
              gain: @layout.gains.map(&:to_f),
              normal: @layout.normal.map(&:to_f),
              order: @layout.order,
              fdn_capacity: loops.zip(taps).map { |l, t| [l, t].max * @max_stretch + fmax + window + 8 },
              damp_coeffs: @layout.damping&.map(&:to_f),
              diff_rate_scale: dmod ? dmod.rate_scales : Array.new(n * stages.length, 1.0),
              diff_phase: dmod ? dmod.phases : Array.new(n * stages.length, 0.0),
              fdn_rate_scale: fmod ? fmod.rate_scales : Array.new(n, 1.0),
              fdn_phase: fmod ? fmod.phases : Array.new(n, 0.0),
              shimmer_phase: Array.new(n) { |i| i.to_f / n },
              dynamics: @dynamics,
            }
          end

          # Runs +count+ samples of +inputs+ (one signal per line: a
          # Numeric or an NArray) through the network.  Returns one reused
          # SFloat buffer per line, or nil if a parameter node ended.
          def process(inputs, count)
            params = @samplers.each_with_index.map { |s, idx|
              next s unless s.is_a?(GraphNode)

              v = s.sample(count)
              return nil if v.nil?

              v = MB::M.zpad(v, count) if v.length < count
              PARAMS[idx][1] == :seconds ? v * @sample_rate : v
            }
            PARAMS.each_with_index do |(_, unit), idx|
              params[idx] = params[idx] * @sample_rate if unit == :seconds && params[idx].is_a?(Numeric)
            end

            if @outputs.empty? || @outputs[0].length != count
              @outputs = Array.new(@layout.lines) { Numo::SFloat.zeros(count) }
            end

            @kernel.process(inputs, @outputs, params, count)
          end

          # Samples processed since the kernel was built.
          def position
            @kernel.position
          end

          # The kernel's LFO values ([diffusion, feedback]).
          def lfo_values
            @kernel.lfo_values
          end
        end
      end
    end
  end
end
