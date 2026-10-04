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

        # Multiplies this node by a one-shot MB::Sound::Envelope (see
        # EnvelopeMethods#adsr) with the given +attack+, +decay+, +sustain+,
        # and +release+ (times in seconds or any length, +sustain+ relative to
        # the peak), at this node's sample rate.  The envelope holds the
        # sustain level for +:hold+ seconds (default: attack plus decay, at
        # least 0.1 s; false for forever), then releases and ends.  Other
        # options (e.g. +:curve+, default :analog) go to Envelope#initialize.
        #
        # Example:
        #     play 220.hz.ramp.adsr(0.005, 0.3, 0.4, 1, curve: :snappy)
        def adsr(attack = nil, decay = nil, sustain = nil, release = nil, **options)
          self * MB::Sound::Envelope.preset(:adsr, attack, decay, sustain, release, sample_rate: sample_rate, **options)
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
          Wavetable.new(wavetable: wavetable, number: number, phase: phase, lookup: lookup, wrap: wrap, sample_rate: phase.sample_rate)
        end
      end
    end
  end
end
