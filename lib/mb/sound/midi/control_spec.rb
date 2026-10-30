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
      # - +curve+ :linear (default) or :exp (geometric, alias :exponential; the range
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
      #
      # Every ControlSpec carries the MB::Sound::Param it was built from
      # (#param: the mapped value's name, default, range, curve, and
      # description, checked as every declaration is); .from_param builds
      # one from a declaration (a knob's, a script's).  Curves use Param's
      # names: canonical :linear, :exp, :switch, with :exponential (and
      # :log, :db) accepted as aliases of :exp.
      class ControlSpec < Data.define(:type, :number, :name, :range, :default, :description, :center, :curve, :param)
        # Controller types, with their raw value ranges, default names, and
        # MIDI status bytes (on channel 1).
        TYPES = {
          cc: { raw: 0..127, status: 0xb0 },
          pressure: { raw: 0..127, status: 0xd0, name: 'Aftertouch', default: 0 },
          poly_pressure: { raw: 0..127, status: 0xa0, name: 'Poly Aftertouch', default: 0 },
          bend: { raw: 0..16383, status: 0xe0, name: 'Pitch Bend', default: 8192 },
        }.freeze

        # A ControlSpec on controller +number+ (+type+ :cc unless given)
        # for +param+ (an MB::Sound::Param): its range in the base unit
        # (+range+ overrides it, e.g. a knob's default 0..1), curve, name,
        # and description, with the raw default at +default_value+'s
        # position (the param's default unless given).
        def self.from_param(param, number: param.cc, type: :cc, range: nil, default_value: nil, name: nil, description: nil, center: nil)
          r = range || param.magnitude_range || (0.0..1.0)
          v = default_value || (param.default.nil? ? r.begin : MB::Sound::Param.magnitude(param.default))
          info = TYPES.fetch(type)
          top = info[:raw].end
          lo = r.begin.to_f
          hi = r.end.to_f
          pos = MB::Sound::Param::Scale.position(v, lo, hi, param.curve)
          raw = (pos * top).round.clamp(0, top)
          new(
            type: type, number: type == :cc ? number : nil, name: name || param.name.to_s, range: r, default: raw,
            description: description || param.description, center: center, curve: param.curve, param: param
          )
        end

        # The mapped value for +raw+ (see #value) of a spec with these
        # fields.
        def self.map(raw, lo, hi, top, center, curve)
          mid = (top + 1) / 2
          return raw >= mid ? hi : lo if curve == :switch

          # (Param::Scale, the one range mapping: a centered controller is
          # two scales, from the center out to each end)
          if center
            c = raw < mid ? (raw - mid) / mid.to_f : (raw - mid) / (top - mid).to_f
            MB::Sound::Param::Scale.value(c.abs, center, c < 0 ? lo : hi, curve)
          else
            MB::Sound::Param::Scale.value(raw / top.to_f, lo, hi, curve)
          end
        end

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

        def initialize(type: :cc, number: nil, name: nil, range: 0.0..1.0, default: nil, description: nil, center: nil, curve: :linear, param: nil)
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
          c = MB::Sound::Param::CURVES[curve]
          raise ArgumentError, "Unknown curve #{curve.inspect} (#{MB::Sound::Param::CURVES.keys.join(', ')})" unless c
          raise ArgumentError, "Range must be a Range of numbers (got #{range.inspect})" unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)

          range = range.begin.to_f..range.end.to_f
          if c == :exp && (range.begin * range.end <= 0 || (center && center * range.begin <= 0))
            raise ArgumentError, "An exponential range can't include or cross 0 (got #{range})"
          end

          name = (name || info[:name] || "CC #{number}").freeze
          center = center&.to_f
          # The declaration of the mapped value (the same record knobs and
          # script options use), at the default raw value's value
          value = ControlSpec.map(default, range.begin, range.end, raw.end, center, c)
          # (an inverted controller's range runs down; the Param's goes up)
          span = range.begin <= range.end ? range : (range.end..range.begin)
          param ||= MB::Sound::Param.new(
            name: name.downcase.gsub(/[^a-z0-9]+/, '_').delete_suffix('_').to_sym, default: value.to_f.clamp(span.begin, span.end),
            range: span, curve: c == :exp || c == :switch ? c : nil, description: description, cc: type == :cc ? number : nil
          )

          super(
            type: type, number: number, name: name, range: range.freeze,
            default: default, description: description&.freeze, center: center, curve: c, param: param
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
          ControlSpec.map(raw, range.begin, range.end, raw_max, center, curve)
        end

        # The 0..1 controller position (raw / #raw_max) that gives +value+:
        # the inverse of #value along its curve and center, which is where a
        # knob learned on the same controller sits (Knob moves by raw /
        # #raw_max), so MIDI::Param::Choice on a cc and a knob on that cc
        # pick alike.  Values outside the range give positions outside
        # 0..1; :switch gives 1.0 for the range's end, else 0.0.
        def position(value)
          lo = range.begin
          hi = range.end
          v = value.to_f
          return v == hi ? 1.0 : 0.0 if curve == :switch
          return MB::Sound::Param::Scale.position(v, lo, hi, curve) unless center

          top = raw_max
          mid = (top + 1) / 2
          # The half from the center toward the value
          upper = (v - center) * (hi - center) >= 0
          c = MB::Sound::Param::Scale.position(v, center, upper ? hi : lo, curve)
          c = 0.0 unless c.finite?
          raw = upper ? mid + c * (top - mid) : mid - c * mid
          raw / top.to_f
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
