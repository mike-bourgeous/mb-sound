module MB
  module Sound
    module Plan
      # A node's state for check mode (Describable#plan_snapshot): #plain is
      # a plain-value form that check mode compares (==), and #data what
      # #restore puts back (deep copies of the instance variables listed).
      class Snapshot
        attr_reader :plain, :data

        def initialize(plain, data)
          @plain = plain
          @data = data
        end

        def ==(other)
          other.is_a?(Snapshot) && other.plain == @plain
        end

        def inspect
          @plain.inspect
        end

        # The instance variables (and extras) that differ from +other+'s, as
        # a String for check mode messages.
        def diff(other)
          a, ax = @plain
          b, bx = other.plain
          keys = (a.keys | b.keys).reject { |k| a[k] == b[k] }
          parts = keys.map { |k| "#{k}: #{a[k].inspect[0, 120]} vs #{b[k].inspect[0, 120]}" }
          parts << "extra: #{ax.inspect[0, 120]} vs #{bx.inspect[0, 120]}" if ax != bx
          parts.join('; ')
        end

        # A snapshot of +node+'s instance variables named in +ivars+, plus
        # +extra+ (a plain value compared too, e.g. a reader's cursor).
        def self.capture(node, ivars, extra = nil)
          data = ivars.to_h { |iv| [iv, node.instance_variable_get(iv)] }
          data = Marshal.load(Marshal.dump(data))
          new([Snapshot.plain(data), extra], data)
        end

        # Restores the instance variables of a #capture.
        def restore(node)
          Marshal.load(Marshal.dump(@data)).each { |iv, v| node.instance_variable_set(iv, v) }
        end

        # A comparable plain form of +v+: Arrays, Hashes, numbers, Symbols,
        # Strings, true/false/nil, Structs and Data as Arrays and Hashes,
        # NArrays as Arrays, other objects as their instance variables.
        def self.plain(v)
          case v
          when Numeric, Symbol, String, true, false, nil then v
          when Array then v.map { |x| plain(x) }
          when Hash then v.to_h { |k, x| [plain(k), plain(x)] }
          when Numo::NArray then [v.class.name, v.to_a]
          when Struct then [v.class.name, plain(v.to_a)]
          when Data then [v.class.name, plain(v.to_h)]
          else
            [v.class.name, v.instance_variables.to_h { |iv| [iv, plain(v.instance_variable_get(iv))] }]
          end
        end
      end
    end
  end
end
