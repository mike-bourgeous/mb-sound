module MB
  module Sound
    module Generative
      # Probability scales that change over time: keyframes of Weights at
      # clip positions, blended between (GitHub issue #64's "blending
      # composited scales for chord and key transitions").  Made with
      # MB::Sound#harmony.  Keys are Durations (`12.bars`, `3.beats`) or
      # plain numbers of bars from the clip's start (0-based); values are
      # Weights, Scales (their notes at 1), or Arrays of notes (a chord).
      #
      #     h = harmony(0 => scale(:dorian, :d), 12.bars => scale(:dorian, :d), 20.bars => scale(:major, :f))
      #     h.at(16.bars)          # halfway from D dorian to F major (Weights)
      #     h.blur(0.2).over(A3..A5, around: E5)   # a Field for each moment
      #
      #     # a looping chord progression, changing on each bar
      #     chords = harmony(0 => [D3, F3, A3], 1.bar => [As2, D3, F3], 2.bars => [G2, As2, D3], 3.bars => [A2, Cs3, E3],
      #                      loop: 4.bars, curve: :step)
      #     h = scale(:dorian, :d).weights + chords * 2
      #
      # +curve:+ shapes each blend: :linear (default), :step (hold each
      # keyframe until the next), or any MB::Sound::Curve name or Curve.
      # +loop:+ (a length) repeats the keyframes, blending from the last one
      # back to the first across the wrap.  Before the first keyframe, the
      # first holds; after the last (without +loop+), the last holds.
      #
      # Operators and #blur apply to the blend at each moment (`h + w`,
      # `h * 2`, `h ** 2`, `h.blur(0.1)`).  Positions are clip positions in
      # whole notes: a generator asks for the Weights where each note
      # starts (see Generator).
      class Harmony
        include Value

        # The keyframes as [[position (whole notes), Weights], ...] by position.
        attr_reader :keys

        # The loop length in whole notes, or nil.
        attr_reader :loop_length

        def initialize(keyframes, curve: :linear, loop: nil, ops: [])
          raise ArgumentError, 'harmony needs keyframes: harmony(0 => scale(:minor, :a), 8.bars => ...)' unless keyframes.is_a?(Hash) && !keyframes.empty?

          @keys = keyframes.map { |pos, w| [Harmony.position(pos), Generative.weights(w)] }.sort_by(&:first).freeze
          raise ArgumentError, 'Harmony keyframes need different positions' if @keys.map(&:first).uniq.length != @keys.length
          @loop_length = loop && Harmony.position(loop)
          raise ArgumentError, "A harmony loop must be longer than its last keyframe (got #{loop.inspect})" if @loop_length && @loop_length <= @keys.last[0]

          @curve_name = curve
          @curve = case curve
                   when :linear, nil then nil
                   when :step then :step
                   else MB::Sound::Curve[curve]
                   end
          @ops = ops.freeze
          # Ops taking other harmonies change with the position even where
          # this one holds still
          @moving = @ops.any? { |_, args, _| args.any? { |a| a.is_a?(Harmony) } }
          @normalized = @keys.map { |_, w| w.send(:normalized_pc) }.freeze
          @keyframes = keyframes
          @options = { curve: curve, loop: loop }
          @cache = {}
          @mutex = Mutex.new
        end

        # A clip position in whole notes from a Duration or a number of bars.
        def self.position(pos)
          case pos
          when Sequence::Duration then pos.whole_notes
          when Numeric
            raise ArgumentError, "Harmony positions are lengths or numbers of bars (got #{pos})" unless pos.real? && pos >= 0
            Sequence::Duration.rational(pos) * Sequence.transport.bar_length
          else
            raise ArgumentError, "Harmony positions are lengths (12.bars) or numbers of bars (got #{pos.inspect})"
          end
        end

        # Freezes after the recipe is set (see Value#with_recipe); the cache
        # stays writable.
        def with_recipe(*)
          super
          self
        end

        # The Weights at clip +position+ (whole notes, or a Duration).
        def at(position = 0r)
          pos = position.is_a?(Sequence::Duration) ? position.whole_notes : position.to_r
          return apply_ops(@keys[0][1], pos) if @keys.length == 1 && @moving
          return @ops.empty? ? @keys[0][1] : held(0) if @keys.length == 1

          # (Harmonies taking other harmonies cache by the full position:
          # the others may loop differently)
          key = @loop_length && !@moving ? pos % @loop_length : pos
          @mutex.synchronize {
            hit = @cache[key]
            return hit if hit
          }
          b = blend_at(pos)
          w = !@moving && (i = @keys.index { |_, k| k.equal?(b) }) ? held(i) : apply_ops(b, pos)
          @mutex.synchronize {
            @cache.shift if @cache.length >= 512
            @cache[key] = w
          }
          w
        end

        # The blend at each moment, blurred (see Weights#blur).
        def blur(amount, reach: 1)
          with_op(:blur, [amount], reach == 1 ? {} : { reach: reach })
        end

        def +(other)
          with_op(:+, [other])
        end

        def -(other)
          with_op(:-, [other])
        end

        def *(other)
          with_op(:*, [other])
        end

        def **(other)
          with_op(:**, [other])
        end

        def coerce(other)
          raise TypeError, "#{other.class} can't be combined with a Harmony" unless other.is_a?(Numeric)
          [self, other]
        end

        # A FieldTimeline: the Field of #at(position) over +range+ (see
        # Weights#over).
        def over(range, around: nil, width: nil)
          FieldTimeline.new(self, range, around: around, width: width).with_recipe(self, :over, [range], { around: around, width: width }.compact)
        end

        def to_s
          "Harmony(#{@keys.map { |pos, w| "#{Sequence::Duration.format(pos)}: #{w}" }.join('; ')}#{" loop #{Sequence::Duration.format(@loop_length)}" if @loop_length})"
        end

        def inspect
          "#<#{self}>"
        end

        def plain_ruby(value_text)
          parts = @keyframes.map { |k, w| "#{value_text.call(k)} => #{w.is_a?(Value) ? w.to_ruby(&value_text) : value_text.call(w)}" }
          parts += @options.compact.reject { |k, v| k == :curve && v == :linear }.map { |k, v| "#{k}: #{value_text.call(v)}" }
          "harmony(#{parts.join(', ')})"
        end

        private

        def with_op(name, args, kwargs = {})
          args.each { |a| raise ArgumentError, "Harmony #{name} takes Weights, Harmonies, or numbers (got #{a.inspect})" unless a.is_a?(Weights) || a.is_a?(Harmony) || a.is_a?(Numeric) }
          h = Harmony.new(@keyframes, **@options, ops: @ops + [[name, args, kwargs].freeze])
          h.with_recipe(self, name, args, kwargs)
        end

        # Keyframe +i+ with the ops applied (cached: a harmony holding still
        # costs nothing per note).
        def held(i)
          @mutex.synchronize { (@held ||= {})[i] } || apply_ops(@keys[i][1], nil).tap { |w| @mutex.synchronize { @held[i] = w } }
        end

        def apply_ops(w, pos)
          @ops.reduce(w) { |acc, (name, args, kwargs)| acc.public_send(name, *args.map { |a| a.is_a?(Harmony) ? a.at(pos) : a }, **kwargs) }
        end

        # The blended Weights at +pos+ (no recipe: a moment's value).
        def blend_at(pos)
          pos %= @loop_length if @loop_length
          first = @keys[0][0]
          if pos < first && !@loop_length
            return @keys[0][1]
          end

          idx = @keys.rindex { |p, _| p <= pos }
          if idx.nil?
            # Before the first keyframe of a loop: blending in from the last
            a_i = @keys.length - 1
            a_pos = @keys[a_i][0] - @loop_length
            b_i = 0
            b_pos = @keys[0][0]
          else
            a_i = idx
            a_pos = @keys[idx][0]
            if idx + 1 < @keys.length
              b_i = idx + 1
              b_pos = @keys[b_i][0]
            elsif @loop_length
              b_i = 0
              b_pos = @keys[0][0] + @loop_length
            else
              return @keys[a_i][1]
            end
          end

          t = ((pos - a_pos) / (b_pos - a_pos)).to_f
          return @keys[a_i][1] if @curve == :step || t <= 0
          t = @curve.call(t) if @curve
          a = @normalized[a_i]
          b = @normalized[b_i]
          Weights.raw(a.each_with_index.map { |x, i| x + (b[i] - x) * t }).freeze
        end
      end

      # The Field of a Harmony at each moment (Harmony#over): #at(position)
      # returns a Field.  Fields are cached by their Weights, so a harmony
      # holding still costs one Field.
      class FieldTimeline
        include Value

        def initialize(harmony, range, around: nil, width: nil)
          @harmony = harmony
          @range = range
          @around = around
          @width = width
          @cache = {}
          @mutex = Mutex.new
          # (checks the range now)
          @notes, @bell = Field.bell(range, around: around, width: width)
        end

        # Every note number in the range (what the timeline's Fields may play).
        attr_reader :notes

        def with_recipe(*)
          super
          self
        end

        # The Field at clip +position+ (whole notes, or a Duration).
        def at(position = 0r)
          w = @harmony.at(position)
          @mutex.synchronize {
            hit = @cache[w.pc]
            return hit if hit
          }
          f = Field.from_bell(@notes, @bell, w.pc).freeze
          @mutex.synchronize {
            @cache.shift if @cache.length >= 512
            @cache[w.pc] = f
          }
          f
        end

        # A note drawn from the Field at the start (for Dice#pick; generators
        # draw from #at(position)).
        def draw(u)
          at(0r).draw(u)
        end

        def to_s
          "FieldTimeline(#{@harmony} over #{@range})"
        end

        def inspect
          "#<#{self}>"
        end

        def plain_ruby(_value_text)
          'nil # FIXME(graph-io): a FieldTimeline without a recipe'
        end
      end
    end
  end
end
