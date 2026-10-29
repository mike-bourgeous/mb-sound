require_relative 'cells'
require_relative 'grid'

begin
  require_relative 'fast_term' # (ext/mb/term/fast_term, built into lib/mb/term)
rescue LoadError
  # Not compiled: Grid.new makes Cells (same text and bytes, slower)
end

module MB
  module Term
    if defined?(FastTerm::Grid)
      # Cells' keyword interface over a native grid (FastTerm::Grid), for
      # NativeCells here and subclasses elsewhere (mb-sound's
      # Plot::Text::NativeCells adds canvas composing).
      module NativeMethods
        # Sets one cell.
        def set(x, y, ch, fg: nil, bg: nil, bold: false, reverse: false)
          set_cell(x, y, ch, Cells.pack(fg), Cells.pack(bg), (bold ? Cells::BOLD : 0) | (reverse ? Cells::REVERSE : 0))
        end

        # Sets the cell at index +i+.
        def put(i, ch, fg, bg, attr)
          y, x = i.divmod(width)
          set_cell(x, y, ch, Cells.pack(fg), Cells.pack(bg), attr)
        end

        # Writes +str+ from (+x+, +y+), clipped to the grid (and to +max+
        # columns).
        def text(x, y, str, fg: nil, bold: false, max: nil)
          put_text(x, y, str, Cells.pack(fg), bold ? Cells::BOLD : 0, max)
        end

        # The lines, with SGR codes for +mode+ (see Cells#lines).
        def lines(mode)
          super(Cells::MODES.fetch(mode, 3))
        end

        # The lines joined by newlines.
        def to_text(mode)
          super(Cells::MODES.fetch(mode, 3))
        end

        # Terminal bytes for the cells, all or those that differ from
        # +prev+ (see Cells#frame).
        def frame(prev, mode, row: 1, col: 1, sync: true)
          super(prev, Cells::MODES.fetch(mode, 3), row, col, sync)
        end

        # Writes #frame to +io+ without holding the GVL; returns the bytes
        # written.
        def write_frame(io, prev, mode, row: 1, col: 1, sync: true)
          super(io, prev, Cells::MODES.fetch(mode, 3), row, col, sync)
        end
      end

      # Cells in C (FastTerm::Grid) with Cells' interface and output.
      class NativeCells < FastTerm::Grid
        include NativeMethods
      end

      Grid.native ||= NativeCells
    end
  end
end
