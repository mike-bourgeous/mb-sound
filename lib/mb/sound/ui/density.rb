module MB
  module Sound
    module UI
      # Layout decisions by terminal size, in one place (ux-1 round 3,
      # pattern E): whether a band gets a rule between it and the console,
      # whether its panes get box-drawn borders with titles and grow taller,
      # whether the tiled screen puts a rule under its one-row header, and
      # which optional panes (`pane :spectrum, only: :big`) show, all from
      # one function of (screen kind, rows, cols).  Band and Tiles ask it on
      # every relayout; `ui.list` and golden captures at 80x24, 120x40, and
      # 236x80 (spec/lib/mb/sound/ui/density_spec.rb) show what it chose.
      #
      #     UI::Density.decide(:band, 24, 80)   # => compact: no rule, no boxes
      #     UI::Density.decide(:band, 80, 236)  # => big: rule, boxes, a taller band
      module Density
        # Rows below which a band gets no rule (the band can't spare a line)
        # and the tiled screen no rule under its header (maintainer,
        # 2026-10-17: "skip the rule below about 25 rows").
        RULE_MIN_ROWS = 25

        # Terminal sizes from which a band scales up (borders with titles,
        # taller panes, the layout's `only: :big` panes).
        BIG_ROWS = 50
        BIG_COLS = 160

        # The share of the terminal's rows a scaled-up band may take.
        BIG_SHARE = 1.0 / 3

        # Levels, smallest first.
        LEVELS = %i[compact normal big].freeze

        # What a screen of +kind+ (:band or :tiles) does at +rows+ x +cols+:
        # +level+ (:compact below RULE_MIN_ROWS, :big from BIG_ROWS x
        # BIG_COLS, else :normal), +rule+ (a band's rule between it and the
        # console), +boxes+ (a band's panes in a frame of rules with their
        # titles set in, like the tiles), +header_rule+ (the tiles' rule under
        # a one-row header), +max_band_rows+ (the most rows a band may grow
        # to; its natural height when it doesn't grow).
        Decision = Data.define(:kind, :rows, :cols, :level, :rule, :boxes, :header_rule, :max_band_rows) do
          def big? = level == :big

          # True for panes shown at this level (a layout's `only:` option).
          def shows?(only)
            only.nil? || LEVELS.index(level) >= LEVELS.index(only)
          end

          def to_s
            parts = [level.to_s]
            parts << 'rule' if rule
            parts << 'boxes' if boxes
            parts << 'header rule' if header_rule
            "#{rows}x#{cols} #{kind}: #{parts.join(', ')}"
          end
        end

        module_function

        # The Decision for a screen of +kind+ (:band, :tiles) at +rows+ x
        # +cols+.
        def decide(kind, rows, cols)
          raise ArgumentError, "Screen kinds are :band and :tiles (got #{kind.inspect})" unless %i[band tiles].include?(kind)
          level = level(rows, cols)
          tall = rows >= RULE_MIN_ROWS
          Decision.new(
            kind: kind, rows: rows, cols: cols, level: level,
            rule: kind == :band && tall,
            boxes: kind == :band && level == :big,
            header_rule: kind == :tiles && tall,
            max_band_rows: level == :big ? (rows * BIG_SHARE).floor : nil
          )
        end

        # :compact, :normal, or :big for a terminal of +rows+ x +cols+.
        def level(rows, cols)
          return :compact if rows < RULE_MIN_ROWS
          return :big if rows >= BIG_ROWS && cols >= BIG_COLS
          :normal
        end

        # The decisions at the sizes the golden captures use, as text lines
        # (for help :ui and the spec).
        def table(sizes = [[24, 80], [40, 120], [80, 236]])
          sizes.flat_map { |r, c| %i[band tiles].map { |k| decide(k, r, c).to_s } }
        end
      end
    end
  end
end
