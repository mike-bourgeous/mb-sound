module MB
  module Sound
    module Sampler
      # A value that depends on the note's key and velocity: the value of
      # the first zone (a key range and a velocity range) holding them, else
      # a default.  Used for settings that a SoundFont sets per zone but a
      # sampler instrument applies around its voice (envelope times and
      # levels, filter cutoffs): Instrument#play makes a GraphNode::ZoneValue
      # of it for each voice, reading the Notes' number and velocity, so the
      # value changes on the note-on sample like the kernel's region choice.
      #
      #     decay = ZoneMap.new([[0..59, 0..127, 4.0], [60..127, 0..127, 1.5]])
      #     inst = Instrument.new(envelope: { segments: [[1, 0.001], [0, decay], [0, 0.3]] }) { ... }
      class ZoneMap
        # The zones: frozen [lo key, hi key, lo velocity, hi velocity,
        # value] Arrays (velocities MIDI 0..127).
        attr_reader :zones

        # The value outside every zone.
        attr_reader :default

        # A ZoneMap of +zones+, or the value itself when every zone has the
        # same one (constants keep the envelope kernel's constant runs).
        def self.of(zones, default: nil)
          values = zones.map(&:last).uniq
          return values[0] if values.length == 1 && (default.nil? || default == values[0])
          new(zones, default: default)
        end

        # +zones+: [keys, velocities, value] (Ranges or [lo, hi] of MIDI
        # numbers); +default+ the value elsewhere (the first zone's value if
        # nil).
        def initialize(zones, default: nil)
          raise ArgumentError, 'A ZoneMap needs at least one zone' if zones.empty?
          @zones = zones.map { |keys, vel, value|
            k = range_of(keys)
            v = range_of(vel)
            [k[0], k[1], v[0], v[1], Float(value)].freeze
          }.freeze
          @default = Float(default.nil? ? @zones[0][4] : default)
          @table = nil
          @mutex = Mutex.new
        end

        # The value for MIDI +key+ and +velocity+.
        def [](key, velocity)
          z = @zones.find { |k0, k1, v0, v1, _| key.between?(k0, k1) && velocity.between?(v0, v1) }
          z ? z[4] : @default
        end

        # The values for every key (rows) and velocity (columns), a
        # 128 × 128 SFloat built on first use (shared by every ZoneValue).
        def table
          @mutex.synchronize {
            @table ||= begin
              t = Numo::SFloat.new(128, 128).fill(@default)
              @zones.reverse_each { |k0, k1, v0, v1, value| t[k0..k1, v0..v1] = value }
              t.freeze
            end
          }
        end

        # A GraphNode::ZoneValue of this map for the notes of +source+ (a
        # Notes) or the +number+ and +velocity+ nodes.
        def node(source = nil, number: nil, velocity: nil)
          number ||= source.number
          velocity ||= source.velocity
          GraphNode::ZoneValue.new(self, number: number, velocity: velocity)
        end

        def ==(other)
          other.is_a?(ZoneMap) && other.zones == @zones && other.default == @default
        end
        alias eql? ==

        def hash
          [@zones, @default].hash
        end

        def to_s
          "ZoneMap (#{@zones.length} zone#{'s' if @zones.length != 1}, #{@zones.map(&:last).minmax.uniq.join('..')})"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        private

        def range_of(r)
          a, b = r.is_a?(Range) ? [r.begin || 0, r.end || 127] : Array(r).values_at(0, -1)
          b -= 1 if r.is_a?(Range) && r.exclude_end? && r.end
          [Integer(a).clamp(0, 127), Integer(b).clamp(0, 127)]
        end
      end
    end
  end
end
