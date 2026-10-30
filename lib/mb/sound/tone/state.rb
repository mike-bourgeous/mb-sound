module MB
  module Sound
    class Tone
      # Everything an oscillator remembers from one sample to the next, in
      # one object with explicit names, so the oscillator's evolution is
      # visible (and can later be saved, restored, or advanced by a fused
      # plan; see the plan-layer notes) instead of scattered over the node.
      #
      # Configuration (wave type, inputs, amplitude, ...) isn't here; neither
      # are caches derived from it (the kernel choice, the output buffer).
      #
      # The Array fields are the exact Arrays the C kernels read and update
      # in place (layouts in fast_synth.c and fast_sound.c):
      # - +phase+: [phase in cycles, 0...1] (FastSound.phasor/oscillate,
      #   FastSynth.oscillate_bl/blit).
      # - +blep+: [previous effective phase, previous increment, previous
      #   phase modulation, primed: 1, or 0 before the first sample, 2 after
      #   a phase jump, previous width, previous pivot in use]
      #   (FastSynth.oscillate_bl).
      # - +blit+: [integrator re, im, gain re, im, previous phase, previous
      #   increment, primed 0/1] (FastSynth.blit).
      # - +sync+: [phase, previous increment, direction +1/-1, ring
      #   position, primed 0/1] and +sync_ring+ (a DFloat of
      #   BandLimit::SYNC_TAPS pending minBLEP corrections)
      #   (FastSynth.oscillate_sync).
      # - +pulses+: [previous phase, previous increment, primed 0/1] for the
      #   wraps/increment ports (BandLimit.sync_pulses).
      # - +noise+: [splitmix64 generator state, an Integer below 2**64] for
      #   noise (FastSound.phasor/oscillate, Tone.noise_random), or nil.
      # - +table+: [sample position in source samples, last phase
      #   modulation, primed (0 or 1), last phase, last increment] for
      #   #wavetable tones
      #   (FastWavetable.oscillate/play, Wavetable::KernelRuby).
      # - +feedback+: [y[n-1], y[n-2], dc], the last two outputs of a
      #   #fm_feedback sine before #at and its DC estimate
      #   (FastSynth.feedback_sine, Tone#feedback_ruby).  Kept across phase
      #   jumps.
      #
      # The other fields:
      # - +jump_residual+: the rest of a band-limited phase jump's step still
      #   to be added to coming samples (a DFloat), or nil.  Kept in a
      #   preallocated step buffer (#jump_buffer, BandLimit::SYNC_TAPS
      #   samples, made at the first jump) with a count of pending samples
      #   (#jump_left), so jumps allocate nothing (#queue_jump and
      #   #add_jump in C: FastSynth.jump_queue/jump_add, mb_jump_step.h;
      #   omnibus18).  #jump_residual reads the pending samples as a view.
      # - +last_freq+, +last_width+, +last_pivot+: frequency (Hz), warp
      #   width, and warp pivot (from a pivot node; nil for a constant) of
      #   the last sample played, where a jump between buffers is measured.
      # - +seed+, +draws+: the random phase generator (see Tone#rnd) as its
      #   seed and the number of numbers drawn, so it can be rebuilt
      #   exactly; nil seed for none.
      # - +reset_ended+: the reset input ended (no more resets).
      #
      # #frame holds scratch for the ports of the current frame (the phase
      # and frequency at its start, and its pieces when resets split it);
      # it isn't carried from one frame to the next.
      #
      # A plain class with accessors was the fastest container measured
      # (bin/osc_state_benchmark.rb).
      class State
        FIELDS = [
          :phase, :blep, :blit, :sync, :sync_ring, :pulses, :noise,
          :jump_residual, :last_freq, :last_width, :last_pivot, :seed, :draws, :reset_ended, :table, :feedback,
        ].freeze

        attr_accessor(*(FIELDS - [:seed, :jump_residual]))
        attr_reader :seed # (#seed= below)

        # The preallocated step buffer of the pending jump residual (a
        # DFloat; a DComplex for complex wavetables), or nil before the
        # first jump, and the number of its samples still pending (see
        # #jump_residual).
        attr_reader :jump_buffer, :jump_left

        # Scratch for the current frame's ports: [phase, frequency,
        # segments] (see the class description).
        attr_accessor :frame_phase, :frame_freq, :frame_segments

        # Creates a state at +phase+ (cycles), ready to play.  Keywords
        # restore any field (see #to_h).
        def initialize(phase: 0.0, **fields)
          extra = fields.keys - FIELDS
          raise ArgumentError, "Unknown state fields #{extra.inspect}" unless extra.empty?

          @phase = phase.is_a?(Array) ? phase.dup : [phase.to_f] # (an Array: with a constant frequency's grid; see #to_h)
          @blep = [0.0, 0.0, 0.0, 0, 0.5, 0.0]
          @blit = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0]
          @sync = [@phase[0], 0.0, 1.0, 0, 0]
          @sync_ring = Numo::DFloat.zeros(BandLimit::SYNC_TAPS)
          @pulses = [0.0, 0.0, 0]
          @noise = nil
          @jump_buffer = nil
          @jump_left = 0
          @last_freq = 0.0
          @last_width = nil
          @last_pivot = nil
          @seed = nil
          @draws = 0
          @rng = nil
          @reset_ended = false
          @table = [0.0, 0.0, 0, 0.0, 0.0]
          @feedback = [0.0, 0.0, 0.0]

          fields.each do |k, v|
            next self.jump_residual = v if k == :jump_residual

            v = Numo::DFloat.cast(v) if k == :sync_ring && v.is_a?(Array)
            v = v.dup if v.is_a?(Array)
            instance_variable_set(:"@#{k}", v)
          end
          @phase = [@phase.to_f] if @phase.is_a?(Numeric)
          restore_rng if @seed
        end

        # The current phase in cycles.
        def phi
          @phase[0]
        end

        # Moves the phase to +cycles+ (wrapped to 0...1).
        def phi=(cycles)
          @phase[0] = (cycles % 1.0).to_f
        end

        # Starts the random phase generator from +seed+ (an Integer), or
        # removes it with nil.
        def seed=(seed)
          @seed = seed.nil? ? nil : Integer(seed)
          @draws = 0
          @rng = @seed && Random.new(@seed)
        end

        # True if there is a random phase generator (see #seed=).
        def random?
          !@rng.nil?
        end

        # The next random phase from the generator (0...1).
        def random
          @draws += 1
          @rng.rand
        end

        # The pending samples of a band-limited phase jump's step (a view
        # of #jump_buffer), or nil if none are pending.
        def jump_residual
          @jump_left > 0 ? @jump_buffer[0...@jump_left] : nil
        end

        # True if samples of a phase jump's step are pending (the
        # allocation-free test of #jump_residual).
        def jump_pending?
          @jump_left > 0
        end

        # Sets the pending step samples (a DFloat or DComplex, an Array of
        # numbers, or nil for none), copying them into the step buffer.
        def jump_residual=(residual)
          residual = Numo::DFloat.cast(residual) if residual.is_a?(Array)
          if residual.nil? || residual.empty?
            @jump_buffer&.fill(0)
            @jump_left = 0
            return
          end

          n = residual.length
          if @jump_buffer.nil? || @jump_buffer.class != residual.class || @jump_buffer.length < n
            @jump_buffer = residual.class.zeros([n, BandLimit::SYNC_TAPS].max)
          else
            @jump_buffer.fill(0)
          end
          @jump_buffer[0...n] = residual
          @jump_left = n
        end

        # Queues a band-limited phase jump step (Tone.jump_residual: value
        # change +dv+, slope change per sample +ds+) times +k+ (unless nil)
        # on top of the pending samples, in place in C for real steps (see
        # FastSynth.jump_queue), else as #queue_jump_ruby.  +real+ keeps
        # only the real part of a complex step (a complex table's jump into
        # a real one).
        def queue_jump(dv, ds, k = nil, real: false)
          return queue_jump_ruby(dv, ds, k, real: real) unless dv.is_a?(Float) && ds.is_a?(Float) && (@jump_buffer.nil? || @jump_buffer.class == Numo::DFloat)

          blep, blamp, area = Tone.jump_tables
          @jump_buffer ||= Numo::DFloat.zeros(BandLimit::SYNC_TAPS)
          c = Tone::JUMP_STEP_AREA * dv + Tone::JUMP_KINK_AREA * ds
          @jump_left = FastSynth.jump_queue(@jump_buffer, @jump_left, blep, blamp, area, dv, ds, k, c)
        end

        # The Ruby reference of #queue_jump (Numo, as Tone#phase_jump and
        # #table_jump did before omnibus18), also its path for complex
        # steps.
        def queue_jump_ruby(dv, ds, k = nil, real: false)
          residual = Tone.jump_residual(dv, ds)
          residual *= k if k
          residual = residual.real if real && residual.is_a?(Numo::DComplex)
          old = jump_residual
          self.jump_residual = old ? residual + Tone.pad_residual(old, residual.length) : residual
        end

        # Adds the pending step samples to +buf+ (times +gain+) and drops
        # what it added: in C for SFloat and DFloat buffers
        # (FastSynth.jump_add), else as #add_jump_ruby.
        def add_jump(buf, gain)
          return unless @jump_left > 0

          if @jump_buffer.class == Numo::DFloat
            left = FastSynth.jump_add(buf, @jump_buffer, @jump_left, gain)
            return @jump_left = left if left
          end
          add_jump_ruby(buf, gain)
        end

        # The Ruby reference of #add_jump (Numo, as Tone#add_jump_residual
        # did before omnibus18), also its path for other types.
        def add_jump_ruby(buf, gain)
          residual = jump_residual
          return unless residual

          n = [buf.length, residual.length].min
          buf[0...n] += residual[0...n] * gain
          self.jump_residual = n < residual.length ? residual[n..].dup : nil
        end

        # Forgets band-limiting history after a phase jump (the kernels
        # start fresh from the new phase).
        def unprime(sync: false)
          @blep[3] = 2 if @blep[3] == 1 # unprimed after a jump (0: never played, stays 0)
          @blit[6] = 0
          @table[2] = 0
          if sync
            @sync = [@phase[0], 0.0, 1.0, 0, 0]
            @sync_ring.fill(0)
          end
        end

        # The state as plain values (Floats, Integers, Arrays, nil), e.g. for
        # saving a graph; State.new(**state.to_h) restores it.
        def to_h
          {
            phase: @phase.length > 1 ? @phase.dup : @phase[0], # (with a constant frequency's grid; see mb_phase.h)
            blep: @blep.dup,
            blit: @blit.dup,
            sync: @sync.dup,
            sync_ring: @sync_ring.to_a,
            pulses: @pulses.dup,
            noise: @noise&.dup,
            jump_residual: jump_residual&.to_a,
            last_freq: @last_freq,
            last_width: @last_width,
            last_pivot: @last_pivot,
            seed: @seed,
            draws: @draws,
            reset_ended: @reset_ended,
            table: @table.dup,
            feedback: @feedback.dup,
          }
        end

        def inspect
          "#<#{self.class.name} #{to_h.reject { |k, _| k == :sync_ring }}>"
        end

        private

        # Rebuilds the generator from #seed and #draws.
        def restore_rng
          @rng = Random.new(@seed)
          @draws.times { @rng.rand }
        end
      end
    end
  end
end
