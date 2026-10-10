module MB
  module Sound
    module Sequence
      # The fills on a Transport's timeline: intervals where named fills
      # play, set ahead of time by a playing Form (see Form::Playback), and
      # read by clips whose notes are marked to play only in fills or only
      # outside them (see Clip#fill, Clip#nofill, and Seq::Step#fill).
      #
      # When fills overlap, the one with the highest +priority+ wins (a
      # section's own fill beats phrase fills, and a longer phrase beats a
      # shorter one), and fills added with +layer: true+ play alongside the
      # winner.
      class FillMap
        # A fill from timeline position +from+ to +to+ (whole notes) named
        # +name+.  +owner+ is whatever added it (for #remove_owner).
        Entry = Data.define(:from, :to, :name, :priority, :layer, :owner)

        # Highest priority (a section's own fill).
        SECTION = Float::INFINITY

        # No fills (frozen).
        NONE = [].freeze

        def initialize
          @entries = [].freeze
          @mutex = Mutex.new
        end

        # Adds a fill named +name+ from +from+ to +to+.  Returns the Entry.
        def add(from, to, name, priority: SECTION, layer: false, owner: nil)
          raise ArgumentError, "Fill names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          e = Entry.new(from: from.to_r, to: to.to_r, name: name, priority: priority, layer: layer, owner: owner)
          @mutex.synchronize { @entries = (@entries + [e]).sort_by(&:from).freeze }
          e
        end

        # Removes the given entries.
        def remove(*entries)
          @mutex.synchronize { @entries = @entries.reject { |e| entries.any? { |x| x.equal?(e) } }.freeze }
        end

        # Removes every entry added by +owner+ that ends after +after+
        # (whole notes; all of them if nil).
        def remove_owner(owner, after: nil)
          @mutex.synchronize {
            @entries = @entries.reject { |e| e.owner.equal?(owner) && (after.nil? || e.to > after) }.freeze
          }
        end

        # Forgets fills that ended before +pos+.
        def prune(pos)
          @mutex.synchronize { @entries = @entries.reject { |e| e.to <= pos }.freeze }
        end

        # Removes every fill.
        def clear
          @mutex.synchronize { @entries = [].freeze }
        end

        # Every entry (frozen).
        def entries
          @entries
        end

        # The names of the fills playing at timeline position +pos+ (a frozen
        # Array, empty outside fills).
        def names_at(pos)
          list = @entries
          return NONE if list.empty?

          active = list.select { |e| e.from <= pos && pos < e.to }
          return NONE if active.empty?

          top = active.reject(&:layer).max_by(&:priority)
          names = active.select(&:layer).map(&:name)
          names.unshift(top.name) if top
          names.uniq.freeze
        end

        # True if any fill plays at +pos+.
        def fill?(pos)
          !names_at(pos).empty?
        end

        def to_s
          "FillMap(#{@entries.map { |e| "#{e.name}@#{e.from}...#{e.to}" }.join(', ')})"
        end
      end
    end
  end
end
