module MB
  module Sound
    module GraphNode
      # Math operators and functions that append arithmetic nodes to a graph
      # (e.g. mixing, multiplication, logarithms, and decibel conversion).
      # Included in GraphNode.
      module ArithmeticMethods
        # Adds +other+ (a number or a node) to this node (a Mixer).
        def +(other)
          return MIDI::Param::Expr.new(:+, self, other) if other.is_a?(MIDI::Param::Base) # (a knob combined with cc(1): a param)
          ArithmeticMethods.check_pitch(:+, self, other)
          # FIXME: this fails to set up the tee correctly when adding a node on the left; see bin/songs/stereo_drone.rb
          Mixer.new([self, other], sample_rate: self.sample_rate)
        end

        # Subtracts +other+ (a number or a node) from this node (a Mixer).
        def -(other)
          return MIDI::Param::Expr.new(:-, self, other) if other.is_a?(MIDI::Param::Base) # (a knob combined with cc(1): a param)
          ArithmeticMethods.check_pitch(:-, self, other)
          Mixer.new([self, [other, -1]], sample_rate: self.sample_rate)
        end

        # Sets how a sum ends: with its last input (+mode+ :all or true, the
        # default for every sum since omnibus8: a gong's long tail plus a
        # short click, a dry part plus its reverb) or with its first (:first
        # or false: a drone plus a hit ending with the hit, the old
        # default).  Applies to this sum and the sums directly inside it
        # (`a + b + c` is two Mixers), not to other nodes; anything else goes
        # through MB::Sound.live_error.  Returns this node.  For every sum a
        # song builds, see Mixer.with_ring, Session#ring, and render(ring:
        # :first).
        #
        #     (drone + hit).ring(:first)        # ends when the hit ends
        #     (pings + noise * n.env(0.001, 0.08)).ring   # (the default) rings past the noise burst
        def ring(mode = :all)
          mode = Mixer.ring_value(mode)
          unless is_a?(Mixer)
            return MB::Sound.live_error(ArgumentError.new("ring(#{mode.inspect}) applies to sums (a + b), not #{self}"))
          end

          todo = [self]
          until todo.empty?
            m = todo.pop
            m.stop_early = mode == :first
            todo.concat(m.summands.grep(Mixer))
          end
          self
        end

        # Multiplies this node by +other+ (a number or a node; a Multiplier).
        def *(other)
          return MIDI::Param::Expr.new(:*, self, other) if other.is_a?(MIDI::Param::Base) # (a knob combined with cc(1): a param)
          Multiplier.new([self, other], sample_rate: self.sample_rate)
        end

        # Scales this node by a number or node, or maps -1..1 onto a Range.  The
        # meaning Tone#at gives full-scale signals: a number or a graph node
        # multiplies (`self * amplitude`), and a Range `a..b` maps -1..1 onto it
        # (`self * (b - a) / 2 + (a + b) / 2`).  Tones keep their own #at,
        # applied inside the oscillator.  Bad values (a Range of Durations,
        # which only Tones take, or anything else) go through
        # MB::Sound.live_error, returning this node unchanged in live mode.
        #
        #     play 220.hz.saw.lp4(800).at(-20.db)
        #     220.hz.saw.filter(:lowpass, cutoff: 3.hz.lfo.lp4(10).at(400..2000))
        #     adsr(0.01, 0.2, 0.5, 0.3).at(0.5)
        def at(amplitude)
          case amplitude
          when Range
            lo, hi = amplitude.begin, amplitude.end
            unless lo.is_a?(Numeric) && hi.is_a?(Numeric) && lo.real? && hi.real?
              if lo.is_a?(Sequence::Duration) || hi.is_a?(Sequence::Duration)
                return at_error('Only Tones take a Range of Durations for #at (e.g. 2.bars.lfo.at(3.n16..5.n16))')
              end
              return at_error("A Range for #at needs two real numbers (got #{amplitude.inspect})")
            end

            half = (hi - lo) / 2.0
            mid = (lo + hi) / 2.0
            mid == 0 ? self * half : self * half + mid

          when Sequence::Duration
            at_error("#at takes a number, a graph node, or a Range of numbers, not a Duration (#{amplitude})")

          when Numeric, GraphNode
            ArithmeticMethods.check_at(amplitude)
            self * amplitude

          else
            at_error("#at takes a number, a graph node, or a Range of numbers (got #{amplitude.inspect})")
          end
        end

        # Warns once per calling line when #at gets a bare number below -1
        # (ux-fix-1, maintainer decision 2026-10-18): `at(-20)` multiplies
        # by -20 (+26 dB, inverted), usually a typo for `at(-20.db)`, but it
        # is valid for control signals (a frequency input), so it isn't an
        # error.  Decibels and gains from -1 to 1 pass silently.
        def self.check_at(amplitude)
          return unless amplitude.is_a?(Numeric) && !amplitude.is_a?(Decibels) && amplitude.real? && amplitude < -1

          n = amplitude.to_f
          text = n == n.round ? n.round.to_s : n.to_s
          Internal.warn_once_per_site(:at_negative,
            "at(#{text}) multiplies by #{text} (#{format('%+.0f', 20 * Math.log10(n.abs))} dB, inverted); " \
            "for a level write at(#{text}.db), for a range at(#{text}..#{text.delete_prefix('-')})")
        end

        # Checks a sum or difference (+op+ :+ or :-) of +left+ and +right+
        # for a Pitch taken as a frequency (ux-notes-2; the maintainer's
        # note 14: `it.hz + 150` meant 150 Hz above the note, but a Pitch
        # used as a signal is a full-scale sine, so it added 150 to the
        # sine, and a cutoff of it sat near 150 Hz).  By the operators rule
        # (signal arithmetic unless type-tagged), the sum stays a sum:
        # - a Pitch and a number (`it.hz + 150`, `150 + it.hz`, also a
        #   Constant): a warning once per calling line, naming the
        #   frequency form (`it.freq + 150`, `590.hz`) and semitones
        #   (`transpose`);
        # - two Pitches (`it.hz + 150.hz`), or a frequency node and a Pitch
        #   (`it.freq + 150.hz`, which adds a 150 Hz sine to the
        #   frequency): MB::Sound.live_error naming `it.freq + 150` (nodes
        #   have no `.hz`; `(it.freq + 150).tone` is an oscillator there)
        #   and, for two sines, `.sine` on each; live mode warns and sums.
        # Tones (`it.hz.saw + 150.hz.sine`) and other nodes pass silently.
        def self.check_pitch(op, left, right)
          lp = left.is_a?(MB::Sound::Pitch)
          rp = right.is_a?(MB::Sound::Pitch)
          return unless lp || rp

          if lp && rp || (rp && !left.is_a?(MB::Sound::Pitch) && ArgTypes.frequency?(left))
            hz = right.constant? ? num(right.frequency) : 'n'
            what = lp ? "#{pitch_text(left)} #{op} #{pitch_text(right)} mixes two full-scale sines (a Pitch used as a signal is a sine)" :
                        "#{freq_text(nil)} #{op} #{pitch_text(right)} #{op == :+ ? 'adds' : 'subtracts'} a full-scale #{hz == 'n' ? '' : "#{hz} Hz "}sine #{op == :+ ? 'to' : 'from'} the frequency"
            hint =
              if lp && left.constant? && right.constant?
                f = op == :+ ? left.frequency + right.frequency : left.frequency - right.frequency
                "for #{num(f)} Hz write #{num(f)}.hz"
              else
                freq = lp ? freq_text(left) : freq_text(nil)
                "for #{hz} Hz #{op == :+ ? 'above' : 'below'} it write #{freq} #{op} #{hz} (a node of Hz, as cutoff: takes; (#{freq} #{op} #{hz}).tone is an oscillator)"
              end
            mix = lp ? "; to mix two sines, #{pitch_text(left)}.sine #{op} #{pitch_text(right)}.sine" : ''
            MB::Sound.live_error(ArgumentError.new("#{what}; #{hint}#{mix}"))
            return
          end

          pitch, other = lp ? [left, right] : [right, left]
          n = other.is_a?(GraphNode::Constant) ? other.constant : other
          return unless n.is_a?(Numeric)

          text = num(n)
          if !lp && op == :-
            Internal.warn_once_per_site(:pitch_arithmetic,
              "#{text} - #{pitch_text(pitch)} subtracts the full-scale sine a Pitch plays as a signal from #{text}, not a frequency; for a frequency use #{freq_text(pitch)}")
            return
          end

          expr = lp ? "#{pitch_text(pitch)} #{op} #{text}" : "#{text} #{op} #{pitch_text(pitch)}"
          hint =
            if pitch.constant?
              f = op == :+ ? pitch.frequency + n : pitch.frequency - n
              "for #{num(f)} Hz write #{num(f)}.hz"
            else
              "for #{text} Hz #{op == :+ ? 'above' : 'below'} it write #{freq_text(pitch)} #{op} #{text} (a node of Hz, as cutoff: takes; (#{freq_text(pitch)} #{op} #{text}).tone is an oscillator)"
            end
          semis = n.abs <= 24 ? ", or #{pitch_text(pitch)}.transpose(#{op == :- ? '-' : ''}#{text}) for semitones" : ''
          Internal.warn_once_per_site(:pitch_arithmetic,
            "#{expr} #{op == :+ ? 'adds' : 'subtracts'} #{text} #{op == :+ ? 'to' : 'from'} the full-scale sine a Pitch plays as a signal (a DC offset), not a frequency; #{hint}#{semis}")
        end

        # How the check names Pitch +p+ in its messages: a Note by its name
        # (C4), a fixed pitch by its Ruby (440.hz), a voice's pitch as
        # `it.hz` (the block's notes, whatever its name).
        def self.pitch_text(p)
          return p.name.to_s if p.respond_to?(:name) && p.is_a?(MB::Sound::Note)
          return "#{num(p.frequency)}.hz" if p.constant?
          defined?(MB::Sound::Notes::NotePitch) && p.is_a?(MB::Sound::Notes::NotePitch) ? 'it.hz' : 'pitch'
        end

        # The frequency node a message suggests for Pitch +p+ (nil: a
        # voice's, `it.freq`).
        def self.freq_text(p)
          p.nil? || (defined?(MB::Sound::Notes::NotePitch) && p.is_a?(MB::Sound::Notes::NotePitch)) ? 'it.freq' : "#{pitch_text(p)}.freq"
        end

        # +x+ as the messages print it: whole numbers without a fraction
        # (Pitches keep Floats: 150, not 150.0), else as Ruby.
        def self.num(x)
          x.is_a?(Numeric) && x.real? && x.finite? && x == x.round ? x.round.to_s : RubyValue.number(x)
        end

        # Divides this node by +other+, a number or a node (a BinaryOperation).
        # For signal graphs, each numerator value is divided by the
        # corresponding denominator value at the same index.
        def /(other)
          BinaryOperation.new(self, other, operator: '/')
        end

        # Raises this node to the power +other+, a number or a node (a
        # BinaryOperation).
        #
        # With a Constant or Knob base (e.g. 10 ** (lfo / 20)) and
        # MB::Sound.precision :fast, raises with the plan layer's fast 2^x
        # (see MB::Sound::Precision), so planned and unplanned agree.
        def **(other)
          BinaryOperation.new(self, other, operator: '**', fast_power_base: is_a?(Constant) || is_a?(Knob) || is_a?(Knob::Reader))
        end

        # The real part of a complex signal (a real signal passes unchanged).
        def real
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :real)
        end

        # The imaginary part of a complex signal (zeros for a real signal).
        def imag
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :imag)
        end

        # The absolute value of a real signal or magnitude of a complex one,
        # antialiased (a full-wave rectifier's corner aliases; see
        # MB::Sound::Shaper).  See #aabs for the exact version for control
        # signals.
        def abs
          MB::Sound::GraphNode::Shaper.new(self, mode: :abs)
        end

        # The plain (aliased, exact) version of #abs.
        def aabs
          MB::Sound::GraphNode::Shaper.new(self, mode: :abs, antialias: false)
        end

        # The instantaneous phase of a complex signal in radians (0 or pi if
        # real).  It is the complex argument, as Numo's and Complex#arg; phase
        # inputs count cycles, so feed it to one as `sig.arg.radians`.
        def arg
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :arg)
        end

        # Rounds values down to integers (a MathFunction node).
        def floor
          MathFunction.new(self, function: :floor)
        end

        # Rounds values up to integers (a MathFunction node).
        def ceil
          MathFunction.new(self, function: :ceil)
        end

        # Rounds values to the nearest integers (a MathFunction node).
        def round
          MathFunction.new(self, function: :round)
        end

        # The natural logarithm of the values (a MathFunction node).
        def log
          MathFunction.new(self, function: :ln)
        end

        # The base two logarithm of the values (a MathFunction node).
        def log2
          MathFunction.new(self, function: :log2)
        end

        # The base ten logarithm of the values (a MathFunction node).
        def log10
          MathFunction.new(self, function: :log10)
        end

        # Lets numbers come first in signal arithmetic (`0.5 * node`; a
        # Constant).
        def coerce(numeric)
          [numeric.constant(sample_rate: self.sample_rate), self]
        end

        private

        # Sends an ArgumentError for #at through MB::Sound.live_error and
        # returns this node unchanged (live mode).
        def at_error(message)
          MB::Sound.live_error(ArgumentError.new(message))
          self
        end
      end
    end
  end
end
