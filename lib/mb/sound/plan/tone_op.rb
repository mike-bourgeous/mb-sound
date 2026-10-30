module MB
  module Sound
    module Plan
      module Op
        # An oscillator: a Tone's whole buffer (the steps in Tone's class
        # comment), with the Tone's own state (Tone::State's Arrays, read
        # and written in place, so planned and unplanned blocks can
        # alternate):
        #
        # - SPLIT at the nonzero samples of +reset+ (a boundary input),
        #   running the kernel on each segment;
        # - PHASE + SHAPE + GAIN in the kernel shared with the node
        #   (mb_osc_shapes.h's naive shapes, as FastSound.oscillate, or
        #   mb_bl_osc.h's PolyBLEP loop, as FastSynth.oscillate_bl);
        # - JUMP: at each reset the executor calls the Tone's own Ruby
        #   (Tone#plan_reset: the target, random phases, and the
        #   band-limited step queued in State#jump_residual), so resets cost
        #   what they cost unplanned, with no fallback; queued steps are
        #   added in C (Tone#add_jump_residual's arithmetic);
        # - the #gain input multiplies the result (Kernels.scale's
        #   arithmetic).
        #
        # P1 covers the :naive and :synth kernels (every naive shape, noise,
        # band-limited ramps, squares, triangles, warped shapes, LFO fades)
        # with frequency, phase modulation, width, reset (with targets and
        # random phases), and gain inputs; P3b the :wavetable kernel for
        # real cycle-mode #wavetable tones and KeyMaps (scan, warps, noise,
        # key zones picked at resets; FastWavetable.oscillate's loop through
        # mb_wavetable.h); tones with sync, ports, timeline locks, feedback,
        # BLIT, clean resets, sample-mode or complex tables stay unplanned
        # (Tone#plan_unsupported_reason).
        #
        # The Ruby mirror is the Tone's own path (Tone#compute, through its
        # kernel's mode; see MB::Sound::Kernels).
        class Tone < Base
          # Kernel numbers in the C executor.
          KERNELS = { naive: 0, synth: 1, wavetable: 2 }.freeze

          # Wave numbers of FastSound.oscillate (enum wave_types in
          # mb_osc_shapes.h) and of the band-limited shapes (enum bl_wave in
          # mb_bl_osc.h).
          WAVES = {
            sine: 0, complex_sine: 1, triangle: 2, complex_triangle: 3, square: 4,
            complex_square: 5, ramp: 6, complex_ramp: 7, gauss: 8, parabola: 9,
          }.freeze
          BL_WAVES = { ramp: 1, square: 2, triangle: 3, sine: 4, parabola: 5 }.freeze

          attr_reader :tone, :frequency, :phase_mod, :width, :reset, :target, :gain, :scan, :kernel

          # Waves with fast shapes at MB::Sound.precision :fast (vectorized
          # real sines; see Plan::VecSine): the unfused Tone uses the same
          # shapes then (FastSound.oscillate, Tone#kernel_ruby), so the op
          # is exact at either precision.
          FAST_WAVES = [:sine].freeze

          # True if this op uses fast shapes (see MB::Sound.precision).
          attr_reader :fast

          def initialize(dst, node, tone, frequency:, phase_mod:, width: nil, reset: nil, target: nil, gain: nil, scan: nil)
            super(dst, node)
            @tone = tone
            @frequency = frequency
            @phase_mod = phase_mod
            @width = width
            @reset = reset
            @target = target
            @gain = gain
            @scan = scan
            @kernel = tone.send(:kernel)
            @fast = Precision.fast? && @kernel == :naive && FAST_WAVES.include?(tone.wave_type) &&
              tone.random_advance == 0 && !dst.complex?

            raise Unsupported.new(tone, "the #{@kernel} kernel") unless KERNELS.include?(@kernel)
            raise Unsupported.new(tone, 'a complex frequency input') if @frequency.complex?
            raise Unsupported.new(tone, 'a complex gain input') if @gain&.complex? && !dst.complex?
            raise Unsupported.new(tone, 'a complex wavetable output') if @kernel == :wavetable && dst.complex?
          end

          def operands
            [@frequency, @phase_mod, @width, @reset, @target, @gain, @scan].grep(Value)
          end

          def expression
            args = ["freq: #{@frequency}"]
            args << "pm: #{@phase_mod}" unless @phase_mod.is_a?(Const) && @phase_mod.value == 0
            args << "width: #{@width}" if @width
            args << "reset: #{@reset}" if @reset
            args << "to: #{@target}" if @target
            args << "gain: #{@gain}" if @gain
            args << "scan: #{@scan}" if @scan && !(@scan.is_a?(Const) && @scan.value == 0)
            "#{@kernel == :synth ? 'bl_' : ''}#{@fast ? 'fast_' : ''}#{@tone.send(:wave_name)}(#{args.join(', ')})"
          end

          def opcode
            :tone
          end

          # The Tone's Ruby path on the same inputs.
          def run_ruby(env, count)
            reset = @reset && env[@reset] # nil once the input ended
            @tone.plan_fast_shapes = @fast
            env[@dst] = @tone.compute(
              count, input(env, @frequency), input(env, @phase_mod), @width && input(env, @width),
              nil, reset, @target && input(env, @target), nil, nil, @scan && input(env, @scan), nil, nil, @gain && input(env, @gain)
            )
          ensure
            @tone.plan_fast_shapes = nil
          end

          private

          # A Const's number, or a Value's buffer (the real parts of a
          # complex one, which is what the C kernels read).
          def input(env, v)
            return v.value if v.is_a?(Const)

            buf = env.fetch(v)
            v.complex? ? buf.real : buf
          end
        end
      end
    end
  end
end
