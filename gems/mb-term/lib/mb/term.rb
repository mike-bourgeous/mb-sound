require_relative 'term/version'
require_relative 'term/cells'
require_relative 'term/grid'
require_relative 'term/native'
require_relative 'term/screen'
require_relative 'term/vt'
require_relative 'term/data_file'
require_relative 'term/themes/theme_set'
require_relative 'term/input/events'
require_relative 'term/input/decoder'
require_relative 'term/input/router'
require_relative 'term/input/repl_host'
require_relative 'term/input/reline_keys'
require_relative 'term/viewports/tree'
require_relative 'term/viewports/tiler'
require_relative 'term/viewports/loader'
require_relative 'term/terminal'

module MB
  # A terminal toolkit in pure Ruby: a cell grid with SGR encoding and
  # changed-cell frames (Cells), a terminal model for what programs write
  # (VT, plus Screen for replaying frames), the real terminal's modes
  # (Terminal), input decoding and a mode router (Input), a pty host for a
  # REPL or any command (Input::ReplHost), split-tree layouts (Viewports),
  # color themes (Themes), and a Prism walker for data files (DataFile).
  # Extracted from mb-sound's terminal UI; see README.md.
  module Term
  end
end
