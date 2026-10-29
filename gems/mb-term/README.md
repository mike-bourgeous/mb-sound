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

## Ruby and C

The grid has two implementations with the same text and bytes:
`MB::Term::Cells` (Ruby) and `MB::Term::NativeCells` (C, the `fast_term`
extension: `rake compile`; without it the gem is pure Ruby).
`MB::Term::Grid.new` picks the C one when it's compiled (`MB_TERM_NATIVE=0`
for Ruby).  The VT, input, layouts, and themes are Ruby only.

Measured with `bench/term_bench.rb 7` (2026-10-29, the Mac container:
i9-9880H under Docker's Linux VM, Ruby 4.0.9; CPU time of one thread, Ruby
and C alternating within each of 7 rounds, medians).  Screens come from a
VT holding an `ls -la --color` style listing; "REPL refresh" is one line
arriving: VT#feed, VT#draw of the changed rows, the frame, and copy_from.

| VT feed (Ruby only: the VT has no C) | bytes | plain ms | plain MB/s | YJIT ms | YJIT MB/s |
|---|---|---|---|---|---|
| Pry transcript | 1051250 | 787.9 | 1.3 | 625.6 | 1.7 |
| ls -la burst | 1415182 | 310.3 | 4.6 | 263.7 | 5.4 |
| full-screen redraws 236x80 | 1402989 | 2070.5 | 0.7 | 1966.2 | 0.7 |

| µs per call | size | Ruby | C | Ruby/C | Ruby +YJIT | C +YJIT | Ruby/C +YJIT | frame bytes |
|---|---|---|---|---|---|---|---|---|
| frame, every cell | 80x24 | 452.5 | 8.2 | 54.9x | 329.0 | 8.9 | 37.0x | 2297 |
| frame, every cell | 120x40 | 1059.3 | 16.2 | 65.3x | 730.6 | 17.5 | 41.8x | 5377 |
| frame, every cell | 236x80 | 3884.9 | 57.1 | 68.0x | 2924.4 | 58.8 | 49.7x | 19968 |
| frame, 3 cells typed | 80x24 | 302.4 | 5.5 | 54.5x | 229.9 | 5.4 | 42.4x | 31 |
| frame, 3 cells typed | 120x40 | 739.0 | 13.0 | 56.8x | 560.7 | 13.1 | 42.7x | 31 |
| frame, 3 cells typed | 236x80 | 2924.3 | 50.7 | 57.6x | 2255.4 | 50.9 | 44.3x | 31 |
| frame, one line scrolled in | 80x24 | 542.2 | 15.1 | 35.9x | 383.4 | 14.5 | 26.4x | 1590 |
| frame, one line scrolled in | 120x40 | 1122.1 | 29.6 | 38.0x | 890.0 | 30.0 | 29.6x | 2632 |
| frame, one line scrolled in | 236x80 | 4260.5 | 86.4 | 49.3x | 3134.8 | 86.0 | 36.4x | 5159 |
| lines (truecolor) | 80x24 | 221.1 | 10.9 | 20.2x | 94.9 | 10.8 | 8.8x |  |
| lines (truecolor) | 120x40 | 480.1 | 27.9 | 17.2x | 212.9 | 24.5 | 8.7x |  |
| lines (truecolor) | 236x80 | 1825.4 | 91.3 | 20.0x | 774.3 | 90.4 | 8.6x |  |
| VT#draw, every row | 80x24 | 771.7 | 168.5 | 4.6x | 513.9 | 72.2 | 7.1x |  |
| VT#draw, every row | 120x40 | 1910.1 | 374.3 | 5.1x | 1275.2 | 153.0 | 8.3x |  |
| VT#draw, every row | 236x80 | 7314.6 | 1185.5 | 6.2x | 5179.3 | 455.1 | 11.4x |  |
| REPL refresh (feed + draw + frame + copy) | 80x24 | 1388.6 | 254.1 | 5.5x | 921.2 | 108.4 | 8.5x |  |
| REPL refresh (feed + draw + frame + copy) | 120x40 | 3121.6 | 518.4 | 6.0x | 2243.3 | 213.3 | 10.5x |  |
| REPL refresh (feed + draw + frame + copy) | 236x80 | 11774.4 | 1386.3 | 8.5x | 8429.7 | 566.6 | 14.9x |  |

Reading it:

- Frame encoding in C is 26-68x faster than Ruby; a whole 236x80 screen
  is 57 µs in C and 2.9-3.9 ms in Ruby.  Scanning for changed cells is
  most of the cost of a small change (3 typed cells: 51 µs in C, 2.3-2.9
  ms in Ruby at 236x80), so the frame cost tracks the screen size, not
  the change.
- With the C grid, the Ruby VT is the rest of a refresh: VT#draw is
  ~80% of a REPL refresh in C (455 of 567 µs at 236x80 with YJIT), and
  VT#feed tops out at 0.7 MB/s for full-screen repaints (a TUI repainting
  236x80 cells in truecolor, ~70 KB each, could repaint ~10 times a
  second), 1.3-1.7 MB/s for Pry's line editing, 4.6-5.4 MB/s for plain
  listings.  A C parser for the VT would be the next step if sharing
  full-screen programs matters.
- In mb-sound's tiled screen (`bin/ui_demo.rb --tiles -s 20 --size
  45x120`, "Last Stop", YJIT, alternating runs, realtime with NullOutput,
  so the wall-clock numbers depend on the machine's load): painter CPU
  per refresh p50 0.51 / 0.95 ms with the C grid and plot kernels vs 3.83 /
  3.76 ms with `MB_SOUND_PLOT=ruby` (p99 2.3 / 4.2 vs 9.5 / 9.6 ms);
  painter GVL holds over 2 ms 40 / 70 vs 1185 / 967 in 20 s.  That
  comparison includes mb-sound's plot kernels, which stay in mb-sound.

## Sharing a REPL over a network (a prototype)

`examples/share_repl.rb` hosts Pry (or any command) on a pty and serves
it to other terminals, without screen or tmux:

```
host$   ruby examples/share_repl.rb host                 # Pry; prints a token
host$   ruby examples/share_repl.rb host -v VIEWTOKEN -- bash
guest$  ssh -N -L 7777:localhost:7777 host &              # a tunnel
guest$  ruby examples/share_repl.rb join -t TOKEN        # watch and type
guest$  ruby examples/share_repl.rb join -t VIEWTOKEN    # watch only
```

The host keeps the program's screen in a VT and sends each viewer the
cells that changed since the frame that viewer last got, at most 30 times
a second (so a slow viewer gets one larger frame later, never a backlog),
or with `join -r` the program's raw bytes.  Late joiners get the whole
screen first.  Ctrl-] q leaves (the host: ends the session).

Security: it listens on 127.0.0.1 unless `--bind` says otherwise (then it
warns: plain TCP carries the token and every key unencrypted); every
viewer sends a token within 5 s (constant-time comparison, a wrong one
waits 1 s); a second token joins read-only; at most 8 viewers.

`share_repl.rb measure` (Pry at 30x100, 110 keys typed at 10 a second,
then 5000 lines of 75 characters printed; bytes on the socket, message
headers included; 2026-10-29, Mac container):

| | frames (30/s) | raw bytes |
|---|---|---|
| typing: bytes per second | 424 | 695 |
| typing: bytes per key | 50 | 82 |
| 5000-line burst: bytes | 3 477 | 359 748 |
| 5000-line burst: messages | 3 | 106 |

Frames cost less than the raw stream while typing (Reline redraws the
whole line per key; a frame sends the changed cells and the cursor) and
far less in bursts (a viewer sees the screen at 30 frames a second, as
with tmux, instead of every line scrolling by).

What a real version would need: TLS or SSH channels (or a Unix socket
with permissions) instead of plain TCP and shared tokens, per-user
accounts and an audit log, resize negotiation (the host's size is fixed;
smaller viewers see the screen clipped), scrollback and copy for viewers,
exact raw-mode joins (a late raw viewer gets the cells and cursor, not
the program's modes like scroll regions), and a C VT parser for
full-screen programs (above).

## Running the specs

The gem's specs run on their own (no mb-sound): from this directory,
`bundle exec rspec` (it uses the parent repository's bundle), or `bundle
exec rake spec:gems` from mb-sound's root.  `spec/boundary_spec.rb`
checks that the code reads only its own constants and Ruby's, requires
only itself and the standard library, and loads in a Ruby without
mb-sound or Bundler.
