module MB
  module Sound
    module GraphNode
      # Methods that use a node to control an oscillator, wavetable, or
      # envelope.  Included in GraphNode.
      module SynthesisMethods
        # Converts a fractional MIDI note number to a frequency in Hz.
        def freq
          self.proc(type_name: 'Number to frequency') { |v|
            MB::FastSound.number_to_freq(v, MB::Sound::Oscillator.tune_note, MB::Sound::Oscillator.tune_freq)
          }
        end

        # Uses this node as the frequency value for an oscillator.
        def tone
          # TODO: add .or_at(1) and go fix all the affected synths and effects
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
          if auto_release.nil?
            auto_release = 2.0 * (attack + decay)
            auto_release = 0.1 if auto_release < 0.1
          end

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
        # See Wavetable#initialize.
        #
        # Example:
        #     # Wavetable oscillator
        #     midi.tone.ramp.wavetable(wavetable: t, number: midi.cc(1))
        def wavetable(wavetable:, number:, lookup: :cubic, wrap: :wrap)
          number = number.constant if number.is_a?(Numeric)
          phase = self
          phase = self.or_at(1) if self.respond_to?(:or_at)
          number = number.or_at(0..1) if number.respond_to?(:or_at)
          Wavetable.new(wavetable: wavetable, number: number, phase: phase, lookup: lookup, wrap: wrap, sample_rate: 48000)
        end
      end
    end
  end
end
