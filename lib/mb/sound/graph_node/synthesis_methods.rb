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
        # amplitude scans 0..1) across its frames.  Levels follow the phase's
        # speed: +increment+ (a node of cycles per sample, or false for the
        # brightest level), a phasor Tone's increment port, or else the
        # phase's own change per sample (see GraphNode::Wavetable).  On a
        # Tone, #wavetable makes the table its waveform instead (see
        # Tone#wavetable); #phase_table always reads at this node's value.
        #
        # Example:
        #     # Phase distortion from a wobbling phase
        #     play (100.hz.phasor + 3.hz.sine.at(0.1)).phase_table(:basic, scan: 0.5)
        def phase_table(table, scan: 0, interpolation: nil, wrap: :wrap, increment: nil)
          scan = scan.or_at(0..1) if scan.is_a?(MB::Sound::Tone)
          increment = self.increment if increment.nil? && is_a?(MB::Sound::Tone) && phasor?
          Wavetable.new(
            table: table, phase: self, scan: scan, increment: increment, interpolation: interpolation,
            wrap: wrap, sample_rate: sample_rate
          )
        end

        # See #phase_table (Tone#wavetable makes a wavetable oscillator).
        def wavetable(table, scan: 0, interpolation: nil, wrap: :wrap, increment: nil)
          phase_table(table, scan: scan, interpolation: interpolation, wrap: wrap, increment: increment)
        end

        # Waveshapes this node through a cycle-mode MB::Sound::Wavetable: the
        # input from -1 to 1 reads across the whole cycle (0 reads the middle;
        # beyond -1..1 the ends), +scan+ as for #phase_table.  Levels follow
        # how fast the input moves (half its change per sample, its peak held
        # for about a buffer), so a loud or high input reads duller levels
        # instead of aliasing; +increment: false+ always reads the brightest
        # level.
        #
        # Example:
        #     play 110.hz.sine.waveshape(:basic, scan: 0.2.hz.lfo.triangle.at(0..1)).at(-12.db)
        def waveshape(table, scan: 0, interpolation: nil, increment: nil)
          phase_table(table, scan: scan, interpolation: interpolation, wrap: :shape, increment: increment)
        end
      end
    end
  end
end
