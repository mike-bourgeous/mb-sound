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
        # the peak), at this node's sample rate.  The envelope releases
        # +:hold+ seconds after it starts (default: twice the attack plus
        # decay, at least 0.1 s; false for forever), then ends.  Other
        # options (e.g. +:curve+, default :analog) go to Envelope#initialize.
        #
        # Example:
        #     play 220.hz.ramp.adsr(0.005, 0.3, 0.4, 1, curve: :snappy)
        def adsr(attack = nil, decay = nil, sustain = nil, release = nil, **options)
          self * MB::Sound::Envelope.preset(:adsr, attack, decay, sustain, release, sample_rate: sample_rate, **options)
        end

        # Reads a cycle-mode MB::Sound::Wavetable (+table+: anything
        # Wavetable.[] accepts) with this node as the phase in cycles (0...1
        # is one cycle), +scan+ (0..1, a number or node; a Tone without an
        # amplitude scans 0..1) across its frames.  A phasor Tone's
        # increment port picks the table's levels (see GraphNode::Wavetable);
        # other phases read the brightest level.  On a Tone, #wavetable makes
        # the table its waveform instead (see Tone#wavetable); #table_lookup
        # always reads at this node's value.
        #
        # Examples:
        #     # Waveshaping a sine (the phase sweeps half a cycle each way)
        #     play 110.hz.sine.at(0.5).table_lookup(:basic, scan: 0.3)
        #     # Phase distortion from a wobbling phase (brightest level: aliases)
        #     play (100.hz.phasor + 3.hz.sine.at(0.1)).table_lookup(:basic, scan: 0.5)
        def table_lookup(table, scan: 0, interpolation: nil, wrap: :wrap, increment: nil)
          scan = scan.or_at(0..1) if scan.is_a?(MB::Sound::Tone)
          increment ||= self.increment if is_a?(MB::Sound::Tone) && phasor?
          Wavetable.new(
            table: table, phase: self, scan: scan, increment: increment, interpolation: interpolation,
            wrap: wrap, sample_rate: sample_rate
          )
        end

        # See #table_lookup (Tone#wavetable makes a wavetable oscillator).
        def wavetable(table, scan: 0, interpolation: nil, wrap: :wrap, increment: nil)
          table_lookup(table, scan: scan, interpolation: interpolation, wrap: wrap, increment: increment)
        end
      end
    end
  end
end
