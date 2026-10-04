module MB
  module Sound
    module MIDI
      # Describes a MIDI controller (CC) as a parameter: its +number+ (0 to
      # 127), a +name+, the +range+ of values it maps to, its +default+ raw
      # value (0 to 127), a +description+, and how raw values map onto the
      # range.  Attached to every controller node (MB::Sound::Notes#cc and
      # the GM-named controls) and collected by MB::Sound::Notes#controls,
      # for documentation, control lists, and ACID XML (planned).
      #
      # Mapping (#value):
      # - +curve+ :linear (default) or :exponential (geometric; the range
      #   must not include 0) or :switch (the range's end at 64 and up, its
      #   beginning below).
      # - Without a +center+, raw 0..127 spreads over the range.
      # - With a +center+ value, raw 64 gives exactly the center, 0 the
      #   range's beginning, and 127 its end, each half mapped separately,
      #   like the GM2 sound controllers (relative changes around 64).
      #
      # Examples:
      #     ControlSpec.new(number: 74, name: 'Brightness', range: 0.25..4.0, center: 1.0, curve: :exponential, default: 64)
      #     ControlSpec.new(number: 1, name: 'Modulation').value(127)   # => 1.0
      class ControlSpec < Data.define(:number, :name, :range, :default, :description, :center, :curve)
        CURVES = [:linear, :exponential, :switch].freeze

        def initialize(number:, name: nil, range: 0.0..1.0, default: 0, description: nil, center: nil, curve: :linear)
          raise ArgumentError, "Controller number must be 0..127 (got #{number.inspect})" unless number.is_a?(Integer) && number.between?(0, 127)
          raise ArgumentError, "Default must be a raw value 0..127 (got #{default.inspect})" unless default.is_a?(Integer) && default.between?(0, 127)
          raise ArgumentError, "Unknown curve #{curve.inspect} (#{CURVES.join(', ')})" unless CURVES.include?(curve)
          raise ArgumentError, "Range must be a Range of numbers (got #{range.inspect})" unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)

          range = range.begin.to_f..range.end.to_f
          if curve == :exponential && (range.begin * range.end <= 0 || (center && center * range.begin <= 0))
            raise ArgumentError, "An exponential range can't include or cross 0 (got #{range})"
          end

          super(
            number: number, name: (name || "CC #{number}").freeze, range: range.freeze, default: default,
            description: description&.freeze, center: center&.to_f, curve: curve
          )
        end

        # Returns the value for a raw controller value (0 to 127; see the
        # class description).
        def value(raw)
          lo = range.begin
          hi = range.end
          return raw >= 64 ? hi : lo if curve == :switch

          if center
            c = raw < 64 ? (raw - 64) / 64.0 : (raw - 64) / 63.0
            far = c < 0 ? lo : hi
            c = c.abs
            curve == :exponential ? center * (far / center) ** c : center + (far - center) * c
          else
            f = raw / 127.0
            curve == :exponential ? lo * (hi / lo) ** f : lo + (hi - lo) * f
          end
        end

        # The value at the default raw value.
        def default_value
          value(default)
        end

        def to_s
          "CC #{number} #{name} (#{MB::M.sigfigs(range.begin, 4)}..#{MB::M.sigfigs(range.end, 4)}" \
            "#{", #{curve}" unless curve == :linear}, default #{default})"
        end
      end
    end
  end
end
