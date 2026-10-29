# mb-term

A terminal toolkit in Ruby, extracted from [mb-sound](../../)'s live
terminal UI (design notes: `design/notes/terminal_ui.md` in mb-sound).
It lives in mb-sound's repository as a path gem (`gem 'mb-term', path:
'gems/mb-term'`); nothing in it knows about sound.

| Part | What it is |
|---|---|
| `MB::Term::Cells` | A grid of character cells (one character per cell, the right half of a wide character `"\0"`), colors packed as `0xRRGGBB` or palette indexes (`Cells::INDEXED \| n`), attribute bits.  `#lines(mode)` gives text with SGR codes in `:truecolor`, `:ansi256`, `:ansi16`, or `:none`; `#frame(prev, mode, row:, col:, sync:)` gives the bytes that draw only the cells that differ from `prev` (cursor moves between runs, short gaps rewritten, DEC 2026 synchronized output). |
| `MB::Term::Grid` | Which grid class to make: `Grid.new(w, h)` is `Cells`, or a native grid with the same interface and bytes once one is registered (`Grid.native = klass`; mb-sound registers its C grid).  `MB_TERM_NATIVE=0` forces Ruby. |
| `MB::Term::ANSI` | SGR color parameters per color mode (nearest xterm-256 and 16-color matches). |
| `MB::Term::VT` | A terminal model for what a program writes: rows of cells, scrollback with stable line numbers, the cursor, and the replies a terminal sends (cursor reports, device attributes, mode reports).  `#draw(grid, x, y, w, h)` copies changed rows into any grid. |
| `MB::Term::Screen` | A small emulator for replaying frames (cursor moves, scroll regions, erases, SGR) into Cells, for specs and captures. |
| `MB::Term::Terminal` | The real terminal while a screen owns it: alternate screen, raw input, bracketed paste, mouse, focus, the kitty keyboard protocol, all undone by `#leave`; probes for DEC 2026, ambiguous width, kitty keys. |
| `MB::Term::Input` | `Decoder` (bytes to Key, Paste, Mouse, Focus, Reply events, keeping each key's bytes), `Keymap`, `Router` (an explicit state machine of input modes: REPL, NAV, line prompts, grabs, overlays, prefixes), `ReplHost` (a REPL or command on a pty, drawn by a VT; `:thread` runs its own Pry, `:adopt` reopens fds 0/1/2 onto the pty), `RelineKeys`. |
| `MB::Term::Viewports` | Immutable split-tree layouts (panes, splits, tabs; fixed sizes, weights, minimums), a Tiler with undo, `to_ruby`, and a loader for layout files. |
| `MB::Term::Themes` | Colors by role and glyph sets, defined in Ruby or theme files. |
| `MB::Term::DataFile` | The one Prism walker for data files (layouts, themes, pane files): calls from a closed table per block level, literal values, LoadErrors with file:line and did-you-mean; never eval. |

```ruby
require 'mb/term'

vt = MB::Term::VT.new(24, 80)
vt.feed("\e[1;32mhello\e[0m world\r\n")
vt.text                 # => "hello world\n..."

grid = MB::Term::Grid.new(80, 24)
prev = MB::Term::Grid.new(80, 24)
vt.draw(grid, 0, 0, 80, 24)
$stdout.write(grid.frame(nil, :truecolor))   # the whole screen
prev.copy_from(grid)
# ... the program writes more ...
vt.draw(grid, 0, 0, 80, 24)
$stdout.write(grid.frame(prev, :truecolor))  # only what changed
```

## The VT model

Enough of a VT100/xterm for line editors (Reline, readline), shells, and
Pry.

Handled:

- C0: CR, LF/VT/FF, BS, HT, BEL (ignored), ESC sequences below.
- ESC: `7`/`8` (DECSC/DECRC), `D` (IND), `E` (NEL), `M` (RI), `c` (RIS);
  character set designations (`( ) * + # % ` and space) are consumed and
  ignored.
- CSI: cursor moves `A B C D E F G H f d e a` and `` ` ``; erases `J`
  (0-3) and `K` (0-2), `X` (ECH); `P` (DCH), `@` (ICH), `L` (IL), `M`
  (DL); `S`/`T` scroll; `r` scroll regions (DECSTBM); `s`/`u` save and
  restore; `g` tab clears; `n` device status (5, 6: cursor position
  report); `c` primary and `>c` secondary device attributes; `?…$p`
  DECRQM mode reports.
- SGR: 0, bold 1, dim 2, italic 3, underline 4, reverse 7 and their
  resets (21-24, 27), 16 colors (30-37, 90-97, 40-47, 100-107), 39/49,
  256 colors (38;5;n / 48;5;n) and truecolor (38;2;r;g;b / 48;2;…).
  Palette colors stay indexes, so the host terminal's own palette shows.
- DEC private modes: 1 (application cursor keys), 6 (origin), 7
  (autowrap), 25 (cursor visible), 47/1047/1049 (alternate screen, 1049
  saving the cursor), 2004 (bracketed paste).
- OSC 0 and 2 (title), and a private OSC used as a sync mark; DCS, APC,
  PM, and SOS strings are consumed and ignored.
- Wide characters take two cells (widths from Reline's table, with the
  ambiguous width as probed); pending wraps; tabs; resizes.

Not handled: left/right margins (DECSLRM), insert mode (IRM), character
sets (line drawing via `ESC ( 0`), double-width or double-height lines,
combining characters (dropped), mouse reporting from the hosted program,
sixel or other images, hyperlinks (OSC 8, ignored), window operations
and LEDs (ignored), cursor styles (DECSCUSR, ignored).

## Running the specs

The gem's specs run on their own (no mb-sound): from this directory,
`bundle exec rspec` (it uses the parent repository's bundle), or `bundle
exec rake spec:gems` from mb-sound's root.  `spec/boundary_spec.rb`
checks that the code reads only its own constants and Ruby's, requires
only itself and the standard library, and loads in a Ruby without
mb-sound or Bundler.
