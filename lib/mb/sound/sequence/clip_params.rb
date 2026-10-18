module MB
  module Sound
    module Sequence
      # Moving parameters (MIDI::Param: knobs, cc, tempo LFOs, clips, and
      # arithmetic on them) in the clip feel and pitch operations
      # (midi-consol-2).  Clips know their future, so they read a param at
      # each event's own clip position (the timeline position for
      # timeline-aligned loops; cycle * length + start) when a cycle's
      # events are made, and #every reads its n at each cycle's start.  Each
      # operation with a param adds a Variation, so every cycle reads anew
      # (a knob turned between cycles changes the next one; see
      # GraphNode::Knob::ValueAt for what a knob answers ahead of time).
      #
      # Lengths given by params are seconds when plain numbers (converted
      # at the current tempo), else Durations or Lengths.
      #
      #     riff.loop.swing(knob(:swing))
      #     riff.loop.chance(4.bars.lfo.at(0.3..1))
      #     riff.loop.transpose(seq(0, 5, 7, 5).n1.loop)   # one step per bar
      #     beat.loop.every(knob(:every).choose(1, 2, 4))
      class Clip
        # Clip operations that take params here (the stream versions read
        # theirs at note-ons; see MIDI::Stream).
        PARAM_OPERATIONS = [:humanize, :quantize, :swing, :chance, :every, :transpose].freeze

        # Prepended over Clip's own operations: a param argument goes to the
        # param versions below, anything else to the original (so plain
        # values give the same clips as before).
        module ParamOperations
          # (Arguments pass through as given, so recipes record the call as
          # written.)
          def humanize(*args, **kwargs)
            time = args.fetch(0, HUMANIZE_TIME)
            velocity = kwargs.fetch(:velocity, 0)
            return super unless MIDI::Param.param?(time) || MIDI::Param.param?(velocity)
            vary = kwargs[:vary]
            humanize_param(time, velocity, kwargs.fetch(:seed, @seed), vary.nil? ? @loop : vary)
          end

          def quantize(*args, **kwargs)
            amount = kwargs.fetch(:amount, 1)
            return super unless MIDI::Param.param?(amount)
            quantize_param(args.fetch(0, Feel::GRID), amount, kwargs.fetch(:ends, false), kwargs[:window])
          end

          def swing(*args, **kwargs)
            amount = args.fetch(0, Feel::SWING)
            return super unless MIDI::Param.param?(amount)
            swing_param(amount, args.fetch(1, Feel::GRID))
          end

          def chance(*args, **kwargs)
            return super unless MIDI::Param.param?(args[0])
            chance_param(args[0])
          end

          def maybe(*args, **kwargs)
            return super unless MIDI::Param.param?(args[0])
            chance_param(args[0])
          end

          def every(*args, **kwargs)
            return super unless MIDI::Param.param?(args[0])
            every_param(args[0], kwargs.fetch(:from, 1))
          end

          def transpose(*args, **kwargs)
            return super unless MIDI::Param.param?(args[0])
            transpose_param(args[0], kwargs[:scale], kwargs[:root])
          end
        end
        prepend ParamOperations

        private

        # Returns this clip with a Variation whose block maps each event of
        # a cycle with +map+, given the event, its clip position, the
        # cycle's start, and a Hash for state kept while one cycle is made
        # (returning an Event, or nil to drop it).
        def param_variation(name, &map)
          with_events(@events, variations: @variations + [Variation.new(name: name, block: ->(events, cycle, clip) {
            offset = clip.looping? ? cycle * clip.length : 0r
            state = { cycle: cycle }
            events.filter_map { |e| map.call(e, offset + e.start, offset, state) }
          })])
        end

        # +x+'s value at clip position +pos+ (see MIDI::Param).
        def param_value(x, pos)
          MIDI::Param.value_at(x, pos, transport: Sequence.current_transport)
        end

        # A param's length value in whole notes (see the class comment).
        def param_whole_notes(v)
          case v
          when Numeric then Duration.rational(v.to_f * Sequence.current_transport.whole_notes_per_second)
          else Duration.whole_notes(v)
          end
        end

        def humanize_param(time, velocity, seed, vary)
          time = MIDI::Param.wrap(time, 'Humanize time')
          velocity = MIDI::Param.wrap(velocity, 'Humanize velocity')
          Feel.check_fraction('Humanize velocity', velocity) unless MIDI::Param.param?(velocity)
          seed = Integer(seed)
          cycle_len = @loop ? @length : nil
          name = "humanize(#{MIDI::Param.label(time)}, velocity: #{MIDI::Param.label(velocity)}, seed: #{seed}#{vary ? '' : ', vary: false'})"
          loop = @loop
          param_variation(name) { |e, pos, _offset, state|
            rng = (state[:rng] ||= Random.new(vary && loop ? Clip.cycle_seed(seed, state[:cycle]) : seed))
            amount = param_whole_notes(param_value(time, pos))
            vel = MB::M.clamp(param_value(velocity, pos).to_f, 0.0, 1.0)
            offset, v = Feel.humanize_draw(rng, e.velocity, vel, both_ways: true)
            start = e.start + Duration.rational(offset * amount.to_f)
            start = cycle_len ? MB::M.clamp(start, -cycle_len + Rational(1, 2**40), 2 * cycle_len - Rational(1, 2**40)) : MB::M.max(start, 0r)
            changes = { start: start }
            changes[:velocity] = v if vel > 0 && e.velocity
            e.with(**changes)
          }
        end

        def quantize_param(grid, amount, ends, window)
          grid = Duration.whole_notes(grid)
          amount = MIDI::Param.wrap(amount, 'Quantize amount')
          window = window && Duration.whole_notes(window)
          length = @length
          loop = @loop
          param_variation("quantize(#{Duration.format(grid)}, amount: #{MIDI::Param.label(amount)})") { |e, pos|
            a = Duration.rational(MB::M.clamp(param_value(amount, pos).to_f, 0.0, 1.0))
            target = Feel.quantize_step(e.start, grid, window: window)
            next e if target.nil?

            start = e.start + (target - e.start) * a
            len = e.length
            if ends
              stop = e.end_time + (Feel.quantize_step(e.end_time, grid) - e.end_time) * a
              len = MB::M.max(stop - start, a == 1 ? grid : 0r)
              len = e.length if len <= 0
            end
            start = loop ? start % length : MB::M.max(start, 0r)
            e.with(start: start, length: len)
          }
        end

        def swing_param(amount, grid)
          amount = MIDI::Param.wrap(amount, 'Swing amount')
          grid = Duration.whole_notes(grid)
          param_variation("swing(#{MIDI::Param.label(amount)}, #{Duration.format(grid)})") { |e, pos|
            a = Duration.rational(MB::M.clamp(param_value(amount, pos).to_f, 0.01, 0.99))
            start = Feel.swing_warp(e.start, a, grid)
            e.with(start: start, length: MB::M.max(Feel.swing_warp(e.end_time, a, grid) - start, 0r))
          }
        end

        def chance_param(p)
          p = MIDI::Param.wrap(p, 'Chance')
          param_variation("chance(#{MIDI::Param.label(p)})") { |e, pos|
            e.with(probability: (e.probability || 1) * MB::M.clamp(param_value(p, pos).to_f, 0.0, 1.0))
          }
        end

        def every_param(n, from)
          n = MIDI::Param.wrap(n, 'every')
          Clip.check_condition(1, from)
          param_variation("every(#{MIDI::Param.label(n)}#{", from: #{from}" if from != 1})") { |e, _pos, offset|
            k = MB::M.max(param_value(n, offset).to_f.round, 1)
            e.with(condition: Clip.check_condition(k, from))
          }
        end

        def transpose_param(step, scale, root)
          step = MIDI::Param.wrap(step, 'Transpose step')
          sc = scale.is_a?(Scale) && root.nil? ? scale : Scale[scale, root]
          param_variation("transpose(#{MIDI::Param.label(step)})") { |e, pos|
            s = param_value(step, pos) || 0
            s = s.number if s.respond_to?(:number) && !s.is_a?(Numeric)
            s = s.round if s.is_a?(Float) && !sc.chromatic?
            steps = MIDI::Transform::Steps.new(s, scale: sc)
            if e.pitch
              raise ArgumentError, "Pitch-marked hits (sampler chops) move by semitones; #{self} can't move by degrees of #{sc}" unless sc.chromatic?
              e.with(pitch: e.pitch + Interval.semitones(steps.degrees + steps.semitones).to_f)
            else
              e.with(value: steps.apply_value(e.value))
            end
          }
        end
      end
    end
  end
end

# Seqs override some of these operations (Seq#transpose, #chance, #every);
# params go to the Clip versions there too (returning Clips).
MB::Sound::Sequence::Seq.prepend(MB::Sound::Sequence::Clip::ParamOperations) if defined?(MB::Sound::Sequence::Seq)
