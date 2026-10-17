module MB
  module Sound
    module UI
      # Rows for a pane's sections by the pane's height (ux-1 r3 item 31,
      # pattern E): a pane declares its sections in screen order, each with
      # a +min+ (rows it needs to show at all), a +pref+ (rows it wants),
      # a +max+, and a +priority+ (0 first), and one function decides the
      # rows: in priority order each section that still fits its minimum
      # gets up to its preferred rows, then what is left grows the sections
      # to their maximums, again in priority order.  So every pane scales
      # the same way (a zoomed keyboard grows taller keys, then a roll of
      # recent notes, ...) instead of handling extra space ad hoc.
      #
      #     Sections.allocate([Sections::Section.new(:head, 1, 1, 1, 0), ...], 30)
      #     # => { head: 1, piano: 14, ... } (screen order, shown sections only)
      module Sections
        Section = Data.define(:name, :min, :pref, :max, :priority) do
          def initialize(name:, min:, pref: min, max: pref, priority: 0)
            raise ArgumentError, "Section #{name}: min <= pref <= max (got #{min}, #{pref}, #{max})" unless min.positive? && min <= pref && pref <= max
            super
          end
        end

        module_function

        # {name => rows} for +sections+ (in screen order) in +rows+ rows:
        # only the sections shown, never more than +rows+ in all, each
        # within its min and max.
        def allocate(sections, rows)
          got = {}
          left = rows
          by_priority = sections.each_with_index.sort_by { |s, i| [s.priority, i] }.map(&:first)
          by_priority.each do |s|
            next if s.min > left
            got[s.name] = [s.pref, left].min
            left -= got[s.name]
          end
          by_priority.each do |s|
            next unless got.key?(s.name) && left > 0
            more = [s.max - got[s.name], left].min
            got[s.name] += more
            left -= more
          end
          sections.filter_map { |s| [s.name, got[s.name]] if got.key?(s.name) }.to_h
        end

        # Canvases for the allocated sections of canvas +c+, top to bottom:
        # {name => Canvas}.
        def canvases(c, sections)
          y = 0
          allocate(sections, c.h).to_h do |name, rows|
            sub = c.sub(0, y, c.w, rows)
            y += rows
            [name, sub]
          end
        end
      end

      # Chord names for held notes (the keyboard pane's readout): the
      # shapes of MIDI::Transform::Chord (maj, min7, sus4, ...) matched on
      # pitch classes, the lowest note as the bass ("Am7", "C/E", "G5").
      module ChordName
        # Shape names as written after the root.
        SUFFIX = {
          maj: '', min: 'm', dim: 'dim', aug: '+', sus2: 'sus2', sus4: 'sus4', power: '5',
          maj7: 'maj7', min7: 'm7', dom7: '7', min7b5: 'm7b5', dim7: 'dim7', min_maj7: 'm(maj7)', maj6: '6', min6: 'm6',
          add9: 'add9', min_add9: 'm(add9)', maj9: 'maj9', min9: 'm9', dom9: '9', min11: 'm11',
        }.freeze

        NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

        module_function

        # The chord name of MIDI +notes+ (Integers), or nil when they make
        # no known shape (a single note is its name).
        def of(notes)
          notes = notes.uniq.sort
          return nil if notes.empty?
          return NAMES[notes[0] % 12] if notes.length == 1

          pcs = notes.map { |n| n % 12 }.uniq
          bass = notes[0] % 12
          found = nil
          # Roots tried from the bass up, so an inversion names its root and bass
          ([bass] + (pcs - [bass])).each do |root|
            set = pcs.map { |p| (p - root) % 12 }.sort
            shape = MIDI::Transform::Chord::SHAPES.find { |name, iv| SUFFIX.key?(name) && iv.map { |i| i % 12 }.uniq.sort == set }
            next unless shape
            found = [root, shape[0]]
            break
          end
          return nil unless found
          root, shape = found
          name = "#{NAMES[root]}#{SUFFIX[shape]}"
          root == bass ? name : "#{name}/#{NAMES[bass]}"
        end
      end
    end
  end
end
