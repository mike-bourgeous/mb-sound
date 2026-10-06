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
      #   phase modulation, primed 0/1] (FastSynth.oscillate_bl).
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
      #
      # The other fields:
      # - +jump_residual+: the rest of a band-limited phase jump's step still
      #   to be added to coming samples (a DFloat), or nil.
      # - +last_freq+, +last_width+: frequency (Hz) and warp width of the
      #   last sample played, where a jump between buffers is measured.
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
          :jump_residual, :last_freq, :last_width, :seed, :draws, :reset_ended, :table,
        ].freeze

        attr_accessor(*FIELDS)

        # Scratch for the current frame's ports: [phase, frequency,
        # segments] (see the class description).
        attr_accessor :frame_phase, :frame_freq, :frame_segments

        # Creates a state at +phase+ (cycles), ready to play.  Keywords
        # restore any field (see #to_h).
        def initialize(phase: 0.0, **fields)
          extra = fields.keys - FIELDS
          raise ArgumentError, "Unknown state fields #{extra.inspect}" unless extra.empty?

          @phase = [phase.to_f]
          @blep = [0.0, 0.0, 0.0, 0]
          @blit = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0]
          @sync = [@phase[0], 0.0, 1.0, 0, 0]
          @sync_ring = Numo::DFloat.zeros(BandLimit::SYNC_TAPS)
          @pulses = [0.0, 0.0, 0]
          @noise = nil
          @jump_residual = nil
          @last_freq = 0.0
          @last_width = nil
          @seed = nil
          @draws = 0
          @rng = nil
          @reset_ended = false
          @table = [0.0, 0.0, 0, 0.0, 0.0]

          fields.each do |k, v|
            v = Numo::DFloat.cast(v) if (k == :sync_ring || k == :jump_residual) && v.is_a?(Array)
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

        # Forgets band-limiting history after a phase jump (the kernels
        # start fresh from the new phase).
        def unprime(sync: false)
          @blep[3] = 0
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
            phase: @phase[0],
            blep: @blep.dup,
            blit: @blit.dup,
            sync: @sync.dup,
            sync_ring: @sync_ring.to_a,
            pulses: @pulses.dup,
            noise: @noise&.dup,
            jump_residual: @jump_residual&.to_a,
            last_freq: @last_freq,
            last_width: @last_width,
            seed: @seed,
            draws: @draws,
            reset_ended: @reset_ended,
            table: @table.dup,
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
