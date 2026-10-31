module MB
  module Sound
    module Plan
      module Op
        # One copy's frequency of a Unison::Detune in :exact mode (fast_plan's
        # OP_UNISON): f × exp(fraction × (d × ln 2 / 12)) in double
        # precision, stored as float, for the detune +detune+ (a Value of
        # semitones, read as float32) and the base frequency +frequency+ (a
        # Value read as float32, or a Const used as a double, as the Detune
        # kernels take a numeric frequency).  Bit for bit what
        # FastUnison.exact gives the copy, and FastUnison.scale for a
        # constant detune (its ratio is the same exp of the same product);
        # the C op computes exp only when the detune changes.  The mirror is
        # Unison::Detune::RubyKernel.exact's arithmetic for one copy.
        class UnisonCopy < Base
          attr_reader :detune, :frequency, :fraction

          def initialize(dst, node, detune, frequency, fraction)
            super(dst, node)
            raise ArgumentError, 'A unison detune must be a Value' unless detune.is_a?(Value)
            raise Unsupported.new(node, 'a complex unison detune or frequency') if detune.complex? || frequency.complex?

            @detune = detune
            @frequency = frequency
            @fraction = fraction.to_f
          end

          def operands
            [@detune, @frequency].grep(Value)
          end

          def expression
            "unison_copy(#{@frequency}, detune: #{@detune}, fraction: #{@fraction})"
          end

          def opcode = :unison

          def run_ruby(env, count)
            read = ->(v) {
              buf = env.fetch(v)
              buf = buf[0...count] if buf.length > count
              Numo::DFloat.cast(Numo::SFloat.cast(buf))
            }
            x = read.(@detune) * MB::Sound::Unison::Detune::LOG_SEMITONE
            f = @frequency.is_a?(Const) ? @frequency.value.to_f : read.(@frequency)
            env[@dst] = Numo::SFloat.cast(f * Numo::NMath.exp(x * @fraction))
          end
        end
      end

      class Builder
        # A unison copy's frequency at +fraction+ of +detune+ semitones around
        # +frequency+ (see Op::UnisonCopy).
        def unison_copy(detune, frequency, fraction)
          d = self[detune]
          d = fill(d) if d.is_a?(Const)
          emit(Op::UnisonCopy.new(value(:real), node, d, self[frequency], fraction))
        end
      end
    end
  end
end
