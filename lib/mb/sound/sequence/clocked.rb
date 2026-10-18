module MB
  module Sound
    module Sequence
      # Clips on their own clocks (see MB::Sound::Clock): `riff.clocked(138.75.bpm)`,
      # `bowl.clocked(19.7.seconds)`, `riff.clocked(5/4r)`,
      # `riff.clocked(:reese)` (a named clock: `clock :reese, 138.75.bpm`).
      # Aliases `clock(x)` and `clocked_at(x)`; the preposition forms
      # `clip.at(x)`, `clip.over(x)`, and `clip % x` pick by the argument's
      # type through one declared table each (ArgTypes::Dispatch: CLIP_AT,
      # CLIP_OVER, CLIP_MOD), and graphs print every one of them as
      # `clocked(...)`.  Transforms keep the clock (`riff.clocked(:x).transpose(2)`
      # stays on :x; see .carry!).
      module Clocked
        # Clip#clocked's typed parameter (the clock is its primary,
        # positional argument; see ArgTypes::Signature).
        SIGNATURE = ArgTypes.register([:clip, :clocked], ArgTypes::Signature.new(:clocked, receiver: 'a clip', params: [
          ArgTypes::Param.new(name: :clock, primary: true, types: {
            tempo: 'plays at that tempo, whatever the session tempo',
            ratio: 'plays at that ratio of the session tempo (following tempo changes)',
            seconds: 'its loop lasts exactly that long (a loop period)',
            name: 'follows the named clock (`clock :tide, 31.1.seconds`)',
          }),
        ]))

        # clip.at(x): by type.
        AT = ArgTypes.register([:clip, :at], ArgTypes::Dispatch.new(:at, receiver: 'a clip', rows: {
          tempo: [:clocked, 'plays at that tempo'],
          ratio: [:clocked, 'plays at that ratio of the session tempo'],
          seconds: [:clocked, 'its loop lasts that long'],
          name: [:clocked, 'follows the named clock'],
        }, note: 'Levels: clip velocities are set with .vel; dB gains belong on the patch (synth.at(-6.db)).'))

        # clip.over(x): the span (a loop period), by type.
        OVER = ArgTypes.register([:clip, :over], ArgTypes::Dispatch.new(:over, receiver: 'a clip', rows: {
          seconds: [:clocked, 'its loop spans that long (a loop period)'],
          name: [:clocked, 'its loop spans one cycle (or the tempo) of the named clock'],
        }, note: 'over is a span: stretching a clip to fit bars is not a clock (scale its notes with .stretch).'))

        # clip % x: the clock, by type.
        MOD = ArgTypes.register([:clip, :%], ArgTypes::Dispatch.new(:%, receiver: 'a clip', rows: {
          tempo: [:clocked, 'plays at that tempo'],
          ratio: [:clocked, 'plays at that ratio of the session tempo'],
          seconds: [:clocked, 'its loop lasts that long'],
          name: [:clocked, 'follows the named clock'],
        }))

        # The clock this clip plays on: a Clock, a clock's name, or nil
        # (the session's timeline).
        def clocking
          @clock
        end

        # This clip on clock +clock+ (see Clocked and MB::Sound::Clock): a
        # Tempo, a Rational ratio of the session tempo, a loop period in
        # seconds, a clock's name, or nil (back on the session's timeline).
        # Also #clock and #clocked_at, and by type #at, #over, and #%.
        def clocked(clock = nil, **kwargs)
          vals = SIGNATURE.bind(clock.nil? ? [] : [clock], kwargs)
          raise ArgumentError, "clocked doesn't take #{vals[:rest].keys.map { |k| "#{k}:" }.join(', ')}" if vals[:rest]
          c = vals[:clock]
          c = MB::Sound::Clock.coerce(c) unless c.nil?
          if c.is_a?(MB::Sound::Clock) && c.unit == :cycles && !(length > 0)
            raise ArgumentError, 'A clip on a loop period needs a length (it spans one period)'
          end
          c = Clocked.check_name(c) if c.is_a?(Symbol)
          dup.tap { |d| d.send(:clock!, c) }
        end

        # See #clocked.
        def clock(x = nil, **kwargs)
          raise ArgumentError, 'clip.clock(x) puts the clip on a clock (138.75.bpm, 5/4r, 19.7.seconds, :tide); clip.clocking reads it' if x.nil? && kwargs.empty?
          clocked(x, **kwargs)
        end

        # See #clocked.
        def clocked_at(x, **kwargs)
          clocked(x, **kwargs)
        end

        # This clip on a clock, by the argument's type (see AT; `help :at`).
        def at(x)
          AT.call(self, x)
        end

        # This clip's loop spanning +x+ (see OVER; `help :over`).
        def over(x)
          OVER.call(self, x)
        end

        # This clip on clock +x+ (see MOD): `bowl % 19.7.seconds`,
        # `riff % 138.75.bpm`, `riff % :reese`.
        def %(other)
          MOD.call(self, other)
        end

        # A clock name checked against the current Session's clocks when
        # it has any (typos raise with suggestions); unknown names are
        # looked up again where the clip plays.
        def self.check_name(name)
          s = MB::Sound::Session.existing
          s.clock!(name) if s && !s.clocks.empty? && !s.clock_named(name)
          name
        end

        private

        def clock!(clock)
          @clock = clock
        end

        # Methods never wrapped by .carry!.
        SKIP = [:clocking, :clocked, :clock, :clocked_at, :at, :over, :%, :named, :name, :each, :events, :rows, :[], :steps, :source, :lineage].freeze

        # Makes every public method of +klass+ returning a Clip keep this
        # clip's clock (unless the result has its own), like PlayedBy.
        def self.carry!(klass)
          names = klass.public_instance_methods - Object.public_instance_methods - Enumerable.public_instance_methods - SKIP
          names = names.reject { |n| n.end_with?('?', '=', '!') || n.start_with?('to_') }
          mod = Module.new
          names.each do |n|
            mod.module_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{n}(...)
                r = super
                return r if @clock.nil? || r.equal?(self) || !r.is_a?(Clip) || !r.clocking.nil?
                r.dup.tap { |d| d.send(:clock!, @clock) }
              end
            RUBY
          end
          klass.prepend(mod)
        end
      end
    end
  end
end
