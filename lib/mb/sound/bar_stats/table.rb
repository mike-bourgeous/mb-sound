module MB
  module Sound
    module BarStats
      # One level of bar statistics (beats, bars, sections, or the song):
      # its rows' keys (+keys+: [bar, beat] pairs, bar numbers, section
      # labels, or [:song]) and its measures as columns: Numo::DFloat
      # columns for numbers (NaN where a measure has no value, e.g. no
      # onset in a band), 2D DFloats (rows x n) for band levels and chroma,
      # and Arrays for keys (Symbols).
      #
      #     t = report.bars
      #     t[:lufs]            # => Numo::DFloat, one value per bar
      #     t.row(0)            # => { bar: 1, seconds: 0.0, lufs: -14.2, ... }
      #     t.at(9)             # the row of bar 9
      class Table
        include Enumerable

        attr_reader :level, :keys, :columns

        # +level+ is :beats, :bars, :sections, or :song; +keys+ one per row;
        # +columns+ a Hash of name => column.
        def initialize(level, keys, columns)
          @level = level
          @keys = keys.freeze
          @columns = columns.freeze
        end

        # A Table from Hash rows (one per key; nil values become NaN in
        # number columns).
        def self.from_rows(level, keys, rows)
          names = rows.flat_map(&:keys).uniq
          columns = names.to_h { |name|
            values = rows.map { |r| r[name] }
            sample = values.compact.first
            col =
              case sample
              when Array
                width = sample.length
                Numo::DFloat.cast(values.map { |v| v ? v.map { |e| e.nil? ? Float::NAN : e.to_f } : Array.new(width, Float::NAN) })
              when Numeric, nil
                Numo::DFloat.cast(values.map { |v| v.nil? ? Float::NAN : v.to_f })
              else
                values.freeze
              end
            col = col.reshape(0, 0) if col.is_a?(Numo::NArray) && values.empty?
            [name, col.is_a?(Numo::NArray) ? col.freeze : col]
          }
          new(level, keys, columns)
        end

        # The column +name+ (KeyError names the columns).
        def [](name)
          @columns.fetch(name) { raise KeyError, "No column #{name.inspect} (columns: #{@columns.keys.join(', ')})" }
        end

        def length = @keys.length
        alias size length

        # The column names.
        def names = @columns.keys

        # Row +i+ as a Hash (NaN back to nil; vectors as Arrays), with its
        # key first (bar:, beat:; bar:; section:).
        def row(i)
          key = @keys[i]
          head =
            case @level
            when :beats then { bar: key[0], beat: key[1] }
            when :bars then { bar: key }
            when :sections then { section: key }
            else { song: true }
            end
          head.merge(@columns.transform_values { |c| Table.value(c, i) })
        end

        # The row whose key is +key+ (a bar number, [bar, beat], or a
        # section label), or nil.
        def at(key)
          i = @keys.index(key)
          i && row(i)
        end

        def each
          return enum_for(:each) unless block_given?
          length.times { |i| yield row(i) }
        end

        # Value +i+ of column +c+ (nil for NaN).
        def self.value(c, i)
          case c
          when Array then c[i]
          else
            if c.ndim == 2
              v = c[i, true].to_a
              v.all?(&:nan?) ? nil : v.map { |e| e.nan? ? nil : e }
            else
              v = c[i]
              v.nan? ? nil : v
            end
          end
        end

        def inspect
          "#<BarStats::Table #{@level}: #{length} rows x #{@columns.length} measures>"
        end
      end
    end
  end
end
