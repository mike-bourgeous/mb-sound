module MB
  module Sound
    class Sample
      # Audio loops on clocks (see MB::Sound::Clock): `loop.clocked(19.7.seconds)`
      # (stretched, pitch kept), `brk.clocked(138.75.bpm)`, `pad.clocked(:tide)`,
      # and by type `loop % 19.7.seconds`, `loop.over(19.7.seconds)`,
      # `brk.at(138.75.bpm)` (Sample#at keeps its sample offsets for lengths
      # and numbers).  Prepended to Sample.
      module Clocked
        # Sample#clocked's typed parameters.
        SIGNATURE = ArgTypes.register([:sample, :clocked], ArgTypes::Signature.new(:clocked, receiver: 'a sample', params: [
          ArgTypes::Param.new(name: :clock, primary: true, types: {
            tempo: 'its beats at that tempo',
            ratio: 'its beats at that ratio of the session tempo',
            seconds: 'one loop in exactly that long (no tempo needed)',
            name: 'follows the named clock',
          }),
        ]))

        # sample.at(x): clocks by type; lengths and numbers stay offsets.
        AT = ArgTypes.register([:sample, :at], ArgTypes::Dispatch.new(:at, receiver: 'a sample', rows: {
          tempo: [:clocked, 'a loop at that tempo'],
          ratio: [:clocked, 'a loop at that ratio of the session tempo'],
          name: [:clocked, 'a loop on the named clock'],
        }, fallback: ->(s, x) { s.send(:offset_at, x) }, fallback_meaning: 'a sample offset (a tracker 9xx): 7.n16, 0.25.seconds, 4800.samples, or a number of samples'))

        # sample.over(x): the span of one loop.
        OVER = ArgTypes.register([:sample, :over], ArgTypes::Dispatch.new(:over, receiver: 'a sample', rows: {
          seconds: [:clocked, 'one loop spans that long (a loop period)'],
          name: [:clocked, 'one loop spans the named clock (its period, or its beats at its tempo)'],
        }))

        # sample % x: the clock, by type.
        MOD = ArgTypes.register([:sample, :%], ArgTypes::Dispatch.new(:%, receiver: 'a sample', rows: {
          tempo: [:clocked, 'a loop at that tempo'],
          ratio: [:clocked, 'a loop at that ratio of the session tempo'],
          seconds: [:clocked, 'one loop in exactly that long'],
          name: [:clocked, 'a loop on the named clock'],
        }))

        # The sample as a loop on clock +clock+ (a Tempo, a Rational ratio,
        # a loop period in seconds, or a clock's name; see MB::Sound::Clock):
        # a GraphNode::LoopPlayer per channel.  When the loop's length on the
        # clock differs from its own, +fit:+ :stretch keeps its pitch
        # (+stretch:+ :auto picks slices for percussive loops and the
        # spectral stretch for tonal ones, as #follow does) and :resample
        # plays it faster or slower (pitch follows the length, tape-style; a
        # speed knob on the clock bends it live).  +align:+ :launch counts
        # its loops from the launch instead of session time.
        #
        #     clock :tide, 19.7.seconds
        #     bg :pad, pad.clocked(:tide)                     # stretched to 19.7 s, pitch kept
        #     bg :tape, pad.clocked(:tide, fit: :resample)    # tape: slower, lower
        #     bg :brk, brk.clocked(138.75.bpm)                # a 138.75 record in a 165 set
        def clocked(clock = nil, fit: :stretch, stretch: :auto, align: :timeline, **kwargs)
          vals = SIGNATURE.bind(clock.nil? ? [] : [clock], kwargs)
          raise ArgumentError, "clocked doesn't take #{vals[:rest].keys.map { |k| "#{k}:" }.join(', ')}" if vals[:rest]
          raise ArgumentError, 'sample.clocked(x): give a clock (19.7.seconds, 138.75.bpm, 5/4r, :tide)' unless vals[:clock]
          fit = { stretch: :stretch, resample: :resample, varispeed: :resample, pitch: :resample }.fetch(fit) {
            raise ArgumentError, "fit: is :stretch (pitch kept) or :resample (pitch follows the length) (got #{fit.inspect})"
          }
          follow(fit, stretch: stretch, align: align, clock: MB::Sound::Clock.coerce(vals[:clock]))
        end

        # See #clocked (by type: AT; lengths and numbers are offsets).
        def at(x)
          AT.row_for(x) ? AT.call(self, x) : super
        end

        # See #clocked (OVER).
        def over(x)
          OVER.call(self, x)
        end

        # See #clocked (MOD).
        def %(other)
          MOD.call(self, other)
        end

        private

        # Sample#at's offsets (a tracker's 9xx), as before clocks.
        def offset_at(offset)
          Sample.instance_method(:at).super_method.bind_call(self, offset)
        end
      end

      prepend Clocked
    end
  end
end
