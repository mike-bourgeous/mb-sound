module MB
  module Sound
    module GraphNode
      # Math operators and functions that append arithmetic nodes to a graph
      # (e.g. mixing, multiplication, logarithms, and decibel conversion).
      # Included in GraphNode.
      module ArithmeticMethods
        # Creates a mixer that adds this node's #sample output to +other+ (a
        # numeric constant or another GraphNode).
        def +(other)
          # FIXME: this fails to set up the tee correctly when adding a node on the left; see bin/songs/stereo_drone.rb
          Mixer.new([self, other], sample_rate: self.sample_rate)
        end

        # Creates a mixer that subtracts +other+ (a numeric constant or another
        # GraphNode) from this node's #sample output.
        def -(other)
          Mixer.new([self, [other, -1]], sample_rate: self.sample_rate)
        end

        # Creates a multiplier that multiplies +other+ (a numeric constant or
        # another GraphNode) by this node's #sample output.
        def *(other)
          Multiplier.new([self, other], sample_rate: self.sample_rate)
        end

        # Scales this node's output, with the meaning Tone#at gives full-scale
        # signals: a number or a graph node multiplies (`self * amplitude`),
        # and a Range `a..b` maps -1..1 onto it (`self * (b - a) / 2 +
        # (a + b) / 2`).  Tones keep their own #at, applied inside the
        # oscillator.  Bad values (a Range of Durations, which only Tones
        # take, or anything else) go through MB::Sound.live_error, returning
        # this node unchanged in live mode.
        #
        #     play 220.hz.ramp.lp4(800).at(-20.db)
        #     220.hz.ramp.filter(:lowpass, cutoff: 3.hz.lfo.lp4(10).at(400..2000))
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
            self * amplitude

          else
            at_error("#at takes a number, a graph node, or a Range of numbers (got #{amplitude.inspect})")
          end
        end

        # Divides incoming data by +other+, which may be a Numeric or another
        # signal graph.  For signal graphs, each numerator value is divided
        # by the corresponding denominator value at the same index.
        def /(other)
          arithmetic_proc(other, '/') { |d1, d2|
            # In place without allocating for real buffers (the same
            # operations as Numo's)
            MB::Sound::FastArithmetic.divide(d1, d2) || d1 / d2
          }
        end

        # Appends a node that raises the incoming values to +other+, which should
        # be either a numeric or another signal graph.
        def **(other)
          arithmetic_proc(other, '**') { |d1, d2|
            MB::Sound::FastArithmetic.power(d1, d2) || d1 ** d2
          }
        end

        # Appends a node that returns the real value of a complex signal, or the
        # unmodified value of a real signal.
        def real
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :real)
        end

        # Appends a node that returns the real value of a complex signal, or
        # zeros for a real signal.
        def imag
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :imag)
        end

        # Appends a node that returns the magnitude of a complex signal, or the
        # absolute value of a real signal, antialiased (a full-wave rectifier's
        # corner aliases; see MB::Sound::Shaper).  See #aabs for the exact
        # version for control signals.
        def abs
          MB::Sound::GraphNode::Shaper.new(self, mode: :abs)
        end

        # The plain (aliased, exact) version of #abs.
        def aabs
          MB::Sound::GraphNode::Shaper.new(self, mode: :abs, antialias: false)
        end

        # Appends a node that returns the instantaneous phase of a complex
        # signal, or zeros or Math::PI for a real signal, in radians (the
        # complex argument, as Numo's and Complex#arg; phase inputs count
        # cycles, so feed it to one as `sig.arg.radians`).
        def arg
          MB::Sound::GraphNode::ComplexNode.new(self, mode: :arg)
        end

        # Rounds values from the node down to the next lower integer (a
        # MathFunction node).
        def floor
          MathFunction.new(self, function: :floor)
        end

        # Raises values from the node to the next higher integer (a
        # MathFunction node).
        def ceil
          MathFunction.new(self, function: :ceil)
        end

        # Rounds values from the node to the nearest integer (a MathFunction
        # node).
        def round
          MathFunction.new(self, function: :round)
        end

        # Appends a node that calculates the natural logarithm of values
        # passing through (a MathFunction node).
        def log
          MathFunction.new(self, function: :ln)
        end

        # Appends a node that calculates the base two logarithm of values
        # passing through (a MathFunction node).
        def log2
          MathFunction.new(self, function: :log2)
        end

        # Appends a node that calculates the base ten logarithm of values
        # passing through (a MathFunction node).
        def log10
          MathFunction.new(self, function: :log10)
        end

        # Wraps the numeric in a MB::Sound::GraphNode::Constant so that numeric values can
        # be listed first in signal graph arithmetic operations.
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

        # Setup/boilerplate buffer management used by #/ and #**.
        def arithmetic_proc(other, name)
          copier = FrozenCopy.new
          if other.respond_to?(:sample)
            other = other.get_sampler

            pr = self.proc({operand: other}, type_name: "#{name} (dynamic)") { |v|
              next nil if v.nil? || v.empty?

              data = other.sample(v.length)

              if data.nil? || data.empty?
                nil
              else
                if data.length != v.length
                  # TODO: allow choosing between padding and truncation (e.g. stop_early)?
                  min_length = MB::M.min(data.length, v.length)
                  data = data[0...min_length]
                  v = v[0...min_length]
                end

                # We can't return v in case types differ, as the type promotion
                # will create a new object, so we grab the yielded value.
                # TODO: should we be operating in place here?  This could modify
                # the source of an upstream ArrayInput for example.
                # A frozen buffer (a Tee's shared buffer, a Constant) is
                # copied (see Tee)
                v = copier.copy(v) if v.frozen?
                v.inplace!
                ret = yield v, data
                ret.not_inplace!
              end
            }.named("#{climb_tee_tree(self).name_or_id} #{name} #{climb_tee_tree(other).name_or_id}")
          else
            pr = self.proc({operand: other}, type_name: "#{name} (constant)") { |v|
              if v.nil? || v.empty?
                nil
              else
                v = copier.copy(v) if v.frozen?
                v.inplace!
                ret = yield v, other
                ret.not_inplace!
              end
            }.named("#{climb_tee_tree(self).name_or_id} #{name} #{other}")
          end

          pr.tap { |pr|
            pr.instance_variable_set(:@operator, name)
            pr.plan_operator = name
            def pr.arithmetic_string(separator = ' ')
              src = climb_tee_tree(@sources.values[0])
              dest = climb_tee_tree(@sources.values[1])
              a = make_source_name(src)
              b = make_source_name(dest)

              "#{a} #{@operator}#{separator}#{b}"
            end
          }
        end
      end
    end
  end
end
