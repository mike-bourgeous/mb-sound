module MB
  module Sound
    module Generative
      # Value objects of the generative layer (Weights, Field, Harmony)
      # remember the expression that made them (+recipe+: receiver, method
      # name, args, kwargs; a nil receiver is a top-level call), so graphs
      # print them back as the Ruby that built them, e.g.
      # `scale(:dorian, D4).weights.blur(0.1) + tones(D3, F3, A3) * 1.2`
      # (GraphNode::Recipe::RubyWriter#generative_text).  Values without a
      # recipe print in a plain form (Weights as `weights(...)` of twelve
      # numbers).
      module Value
        # [receiver, name, args, kwargs] or nil.
        attr_reader :recipe

        # Sets the recipe (once, while building; values are frozen after).
        def with_recipe(receiver, name, args = [], kwargs = {})
          @recipe = [receiver, name, args.freeze, kwargs.freeze].freeze unless frozen?
          self
        end

        # Ruby for this value, with +value_text+ (a block) printing other
        # values (Scales, Notes, numbers); used by the recipe writer.  Plain
        # inspect-based printing without a block.
        def to_ruby(&value_text)
          value_text ||= ->(v) { RubyValue.to_ruby(v, gains: true) }
          Value.text(self, value_text)
        end

        # Operators by precedence, for parentheses (lower binds looser).
        BINARY = { :+ => 1, :- => 1, :* => 2, :/ => 2, :** => 3 }.freeze

        def self.text(v, value_text)
          return v.plain_ruby(value_text) unless v.recipe

          receiver, name, args, kwargs = v.recipe
          if (prec = BINARY[name]) && receiver && args.length == 1 && kwargs.empty?
            left = operand(receiver, value_text, prec, false)
            right = operand(args[0], value_text, prec, true)
            return "#{left} #{name} #{right}"
          end

          parts = args.map { |a| arg_text(a, value_text) } + kwargs.map { |k, x| "#{k}: #{arg_text(x, value_text)}" }
          # A trailing Hash of keyframes prints without braces: harmony(0 => a, 12.bars => b)
          parts[args.length - 1] = parts[args.length - 1][2..-3] if args.last.is_a?(Hash) && !args.last.empty?
          call = "#{name}#{"(#{parts.join(', ')})" unless parts.empty?}"
          return call if receiver.nil?

          r = receiver.is_a?(Value) ? text(receiver, value_text) : value_text.call(receiver)
          r = "(#{r})" if receiver.is_a?(Value) && receiver.recipe && BINARY.key?(receiver.recipe[1])
          "#{r}.#{call}"
        end

        def self.arg_text(a, value_text)
          case a
          when Value then text(a, value_text)
          when Hash
            # harmony(0 => a, 12.bars => b): keys and values may be values
            "{ #{a.map { |k, x| "#{arg_text(k, value_text)} => #{arg_text(x, value_text)}" }.join(', ')} }"
          else value_text.call(a)
          end
        end

        def self.operand(x, value_text, prec, right)
          t = arg_text(x, value_text)
          inner = x.is_a?(Value) && x.recipe && BINARY[x.recipe[1]]
          inner = 1 if !inner && x.is_a?(Numeric) && x.real? && x.negative?
          # Equal precedence: parenthesize the side Ruby wouldn't group
          # (the right one, or the left of right-associative **), so values
          # rebuild with the same rounding
          paren = inner && (inner < prec || (inner == prec && (right ? prec != 3 : prec == 3)))
          paren ? "(#{t})" : t
        end
      end
    end
  end
end
