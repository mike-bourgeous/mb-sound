module MB
  module Sound
    module GraphNode
      # Methods that use a node to control an oscillator, wavetable, or
      # envelope.  Included in GraphNode.
      module SynthesisMethods
        # Converts a fractional MIDI note number to a frequency in Hz with the
        # current tuning, following tuning changes (see MB::Sound.tuning).
        def freq
          MB::Sound.tuning.freq(self)
        end

        # Uses this node as the frequency value for a full-scale oscillator.
        def tone
          MB::Sound::Tone[self]
        end

        # Multiplies this envelope by an ADSR envelope with the given +attack+,
        # +decay+, +sustain+, and +release+ parameters, with times in seconds,
        # and +sustain+ ranging from 0 to 1 (typically).
        #
        # If +:log+ is given, then the envelope will be converted to a
        # logarithmic envelope ranging from +:log+ decibels (e.g. `-30`) to 1.0.
        #
        # If the +:auto_release+ parameter is a number of seconds (defaults to 2x
        # attack + decay, or 0.25, whichever is longer; set it to false to
        # disable), then the envelope will release automatically after that time.
        def adsr(attack, decay, sustain, release, log: nil, auto_release: nil, filter_freq: 10000)
          auto_release = MB::Sound::ADSREnvelope.default_auto_release(attack, decay, sample_rate: sample_rate) if auto_release.nil?

          env = MB::Sound::ADSREnvelope.new(
            attack_time: attack,
            decay_time: decay,
            sustain_level: sustain,
            release_time: release,
            sample_rate: self.sample_rate,
            filter_freq: filter_freq
          )

          env.trigger(1.0, auto_release: auto_release)

          # TODO: this log parameter still doesn't seem like the right interface
          env = env.db(log) if log

          self * env
        end

        # Uses this node as the phase of a wavetable, with the given +:wavetable+
        # 2D NArray and +:number+.
        #
        # +:wavetable+ - A 2D NArray to use as the wavetable.
        # +:number+ - A GraphNode or Numeric to control wave number.
        # +:lookup+ - Interpolation mode (noisy :linear or cleaner :cubic).
        # +:wrap+ - A wrapping mode constant, or a MIDI value.
        #
        # See Wavetable#initialize.  A ramp Tone used as the phase is switched
        # to its naive shape (Tone#aramp), since a phase must wrap exactly (a
        # band-limited ramp would read the middle of the table at each wrap).
        #
        # Example:
        #     # Wavetable oscillator
        #     midi.tone.ramp.wavetable(wavetable: t, number: midi.cc(1))
        def wavetable(wavetable:, number:, lookup: :cubic, wrap: :wrap)
          number = number.constant if number.is_a?(Numeric)
          phase = self
          phase = phase.aramp if phase.is_a?(Tone) && phase.wave_type == :ramp
          phase = phase.or_at(1) if phase.respond_to?(:or_at)
          number = number.or_at(0..1) if number.respond_to?(:or_at)
          Wavetable.new(wavetable: wavetable, number: number, phase: phase, lookup: lookup, wrap: wrap, sample_rate: 48000)
        end
      end
    end
  end
end
