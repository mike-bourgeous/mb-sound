module MB
  module Sound
    module Sampler
      # The choke groups of an Instrument's regions (Instrument#region's
      # +choke:+, +group:+, +off_by:+; SF2 exclusive classes, SFZ group= and
      # off_by=), by key and velocity, for MIDI::Allocator#add_chokes: a
      # note-on starting groups (#groups) chokes every sounding note of the
      # same channel whose regions are cut by one of them (#choked_by).
      #
      # A note counts every region holding its key and velocity (all
      # layers' regions, round robins too), the region choice the kernel
      # makes at the note-on aside, so keys shouldn't mix groups across
      # round robins.  Two ChokeMaps with the same rows are equal, so the
      # many lanes of one synth register one map.
      class ChokeMap
        # Frozen [lo key, hi key, lo velocity, hi velocity, group, off_by]
        # rows (velocities MIDI 0..127; group and off_by nil or a value).
        attr_reader :rows

        def initialize(rows)
          @rows = rows.map { |r| r.dup.freeze }.freeze
          @cache = {}
          @mutex = Mutex.new
        end

        # The groups a note-on of MIDI +note+ (a number or Note) at
        # +velocity+ (0..1, as MIDI::Event#velocity) starts (a frozen Array,
        # maybe empty).
        def groups(note, velocity)
          lookup(note, velocity)[0]
        end

        # The groups whose note-ons cut a note of MIDI +note+ started at
        # +velocity+ (a frozen Array, maybe empty).
        def choked_by(note, velocity)
          lookup(note, velocity)[1]
        end

        def ==(other)
          other.is_a?(ChokeMap) && other.rows == @rows
        end
        alias eql? ==

        def hash
          @rows.hash
        end

        def to_s
          "ChokeMap (#{@rows.length} region#{'s' if @rows.length != 1}, groups #{@rows.flat_map { |r| r[4..5] }.compact.uniq.inspect})"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        private

        # [groups, off_by groups] for +note+ and +velocity+ (rounded like
        # the kernel's region choice), cached.
        def lookup(note, velocity)
          key = (Sample.note_number(note) + 0.5).floor.clamp(0, 127) * 128 + (velocity.to_f * 127.0 + 0.5).floor.clamp(0, 127)
          @mutex.synchronize {
            @cache[key] ||= begin
              k = key / 128
              v = key % 128
              hits = @rows.select { |k0, k1, v0, v1, _, _| k.between?(k0, k1) && v.between?(v0, v1) }
              [hits.map { |r| r[4] }.compact.uniq.freeze, hits.map { |r| r[5] }.compact.uniq.freeze].freeze
            end
          }
        end
      end
    end
  end
end
