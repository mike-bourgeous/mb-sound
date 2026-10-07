module MB
  module Sound
    module MIDI
      # Describes a MIDI controller as a parameter: its +type+ (:cc, the
      # default, :bend for pitch bend, :pressure for channel pressure, or
      # :poly_pressure for polyphonic key pressure),
      # its +number+ (0 to 127, CCs only; nil otherwise), a +name+, the
      # +range+ of values it maps to, its +default+ raw value (0 to 127, or
      # 0 to 16383 for pitch bend), a +description+, and how raw values map
      # onto the range.  Attached to every controller node
      # (MB::Sound::Notes#cc, the GM-named controls, #bend, and #pressure)
      # and collected by MB::Sound::Notes#controls, for documentation,
      # control lists, and ACID XML (MIDI::ControlMap).
      #
      # Mapping (#value):
      # - +curve+ :linear (default) or :exponential (geometric; the range
      #   must not include 0) or :switch (the range's end at 64 and up, its
      #   beginning below).
      # - Without a +center+, raw 0..127 spreads over the range.
      # - With a +center+ value, the middle raw value (64, or 8192 for pitch
      #   bend) gives exactly the center, 0 the range's beginning, and the
      #   top (127 or 16383) its end, each half mapped separately, like the
      #   GM2 sound controllers (relative changes around 64) and pitch bend
      #   (MIDI::Event.bend_value).
      #
      # Examples:
      #     ControlSpec.new(number: 74, name: 'Brightness', range: 0.25..4.0, center: 1.0, curve: :exponential, default: 64)
      #     ControlSpec.new(number: 1, name: 'Modulation').value(127)   # => 1.0
      #     ControlSpec.bend(range: -2.0..2.0).value(16383)              # => 2.0
      #     ControlSpec.pressure.value(127)                               # => 1.0
      class ControlSpec < Data.define(:type, :number, :name, :range, :default, :description, :center, :curve)
        CURVES = [:linear, :exponential, :switch].freeze

        # Controller types, with their raw value ranges, default names, and
        # MIDI status bytes (on channel 1).
        TYPES = {
          cc: { raw: 0..127, status: 0xb0 },
          pressure: { raw: 0..127, status: 0xd0, name: 'Aftertouch', default: 0 },
          poly_pressure: { raw: 0..127, status: 0xa0, name: 'Poly Aftertouch', default: 0 },
          bend: { raw: 0..16383, status: 0xe0, name: 'Pitch Bend', default: 8192 },
        }.freeze

        # A pitch bend spec: -1..1 by default (MIDI::Event#value), centered
        # at raw 8192.  Pass +range+ in semitones (e.g. -2.0..2.0) for a
        # bend in semitones.
        def self.bend(range: -1.0..1.0, name: nil, description: 'Pitch bend', center: :middle, **options)
          center = (range.begin + range.end) / 2.0 if center == :middle
          new(type: :bend, range: range, name: name, description: description, center: center, **options)
        end

        # A channel pressure (aftertouch) spec, 0..1 by default.
        def self.pressure(range: 0.0..1.0, name: nil, description: 'Channel pressure', **options)
          new(type: :pressure, range: range, name: name, description: description, **options)
        end

        # A polyphonic key pressure (poly aftertouch) spec, 0..1 by default.
        # Listed by control maps, but left out of ACID XML (ACID maps a
        # parameter to one controller, and poly pressure is per key).
        def self.poly_pressure(range: 0.0..1.0, name: nil, description: 'Polyphonic key pressure', **options)
          new(type: :poly_pressure, range: range, name: name, description: description, **options)
        end

        def initialize(type: :cc, number: nil, name: nil, range: 0.0..1.0, default: nil, description: nil, center: nil, curve: :linear)
          info = TYPES[type]
          raise ArgumentError, "Unknown controller type #{type.inspect} (#{TYPES.keys.join(', ')})" unless info

          if type == :cc
            raise ArgumentError, "Controller number must be 0..127 (got #{number.inspect})" unless number.is_a?(Integer) && number.between?(0, 127)
          elsif !number.nil?
            raise ArgumentError, "Only CCs have numbers (got #{number.inspect} for #{type})"
          end

          default = info[:default] || 0 if default.nil?
          raw = info[:raw]
          raise ArgumentError, "Default must be a raw value #{raw} (got #{default.inspect})" unless default.is_a?(Integer) && raw.cover?(default)
          raise ArgumentError, "Unknown curve #{curve.inspect} (#{CURVES.join(', ')})" unless CURVES.include?(curve)
          raise ArgumentError, "Range must be a Range of numbers (got #{range.inspect})" unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)

          range = range.begin.to_f..range.end.to_f
          if curve == :exponential && (range.begin * range.end <= 0 || (center && center * range.begin <= 0))
            raise ArgumentError, "An exponential range can't include or cross 0 (got #{range})"
          end

          super(
            type: type, number: number, name: (name || info[:name] || "CC #{number}").freeze, range: range.freeze,
            default: default, description: description&.freeze, center: center&.to_f, curve: curve
          )
        end

        # True for a control change (CC) spec.
        def cc?
          type == :cc
        end

        # The highest raw value: 127, or 16383 for pitch bend.
        def raw_max
          TYPES[type][:raw].end
        end

        # The MIDI status byte of this controller on channel 1 (176 for CCs,
        # 208 for channel pressure, 224 for pitch bend).
        def status
          TYPES[type][:status]
        end

        # A key that sorts CCs by number, then channel pressure, then pitch
        # bend (by status byte), and groups specs on the same controller.
        def key
          return [TYPES[:pressure][:status], -1] if type == :poly_pressure # after the CCs, before channel pressure
          [status, number || 0]
        end

        # Returns the value for a raw controller value (0 to #raw_max; see
        # the class description).
        def value(raw)
          lo = range.begin
          hi = range.end
          top = raw_max
          mid = (top + 1) / 2
          return raw >= mid ? hi : lo if curve == :switch

          if center
            c = raw < mid ? (raw - mid) / mid.to_f : (raw - mid) / (top - mid).to_f
            far = c < 0 ? lo : hi
            c = c.abs
            curve == :exponential ? center * (far / center) ** c : center + (far - center) * c
          else
            f = raw / top.to_f
            curve == :exponential ? lo * (hi / lo) ** f : lo + (hi - lo) * f
          end
        end

        # The value at the default raw value.
        def default_value
          value(default)
        end

        def to_s
          "#{"CC #{number} " if cc?}#{name} (#{MB::M.sigfigs(range.begin, 4)}..#{MB::M.sigfigs(range.end, 4)}" \
            "#{", #{curve}" unless curve == :linear}, default #{default})"
        end
      end
    end
  end
end
