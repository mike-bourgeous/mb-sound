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
| `MB::Term::VT` | A terminal model for what a program writes: rows of cells, scrollback with stable line numbers, the cursor, and the replies a terminal sends (cursor reports, device attributes, mode reports).  `#draw(grid, x, y, w, h)` copies changed rows into any grid.  `VT.new` makes a `NativeVT` (C) when fast_term is compiled, else a `RubyVT` (its reference: same state, same cells). |
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
  ambiguous width as probed; dropped in a one-column VT); pending wraps;
  tabs; resizes.
- Parameters are their leading digits (`3:9` reads as 3; none: 0),
  saturating at 65535 (`VT::PARAM_MAX`); empty ones take their default,
  and in `r` 0 does too (`CSI 0;0 r` is the whole screen, as in xterm).
  Invalid UTF-8 becomes `?` as `String#scrub` replaces it.  Bytes split
  anywhere between reads (inside sequences, characters, or invalid
  bytes) give the state they give read at once.

Not handled: left/right margins (DECSLRM), insert mode (IRM), character
sets (line drawing via `ESC ( 0`), double-width or double-height lines,
combining characters (dropped), mouse reporting from the hosted program,
sixel or other images, hyperlinks (OSC 8, ignored), window operations
and LEDs (ignored), cursor styles (DECSCUSR, ignored).

## Ruby and C

The grid and the VT each have two implementations with the same results:
`MB::Term::Cells` and `MB::Term::NativeCells` (the same text and bytes),
`MB::Term::RubyVT` and `MB::Term::NativeVT` (the same state after the same
bytes, the same cells drawn).  The C ones are the `fast_term` extension
(`rake compile`; without it the gem is pure Ruby); `MB::Term::Grid.new` and
`MB::Term::VT.new` pick them when it's compiled (`MB_TERM_NATIVE=0` for
Ruby).  The Ruby VT is the reference: `spec/vt_native_spec.rb` compares
both over captured streams and seeded random bytes (`VT_FUZZ=N` for more,
`VT_FUZZ_SEED=n` to repeat a case).  NativeVT's `#line_at` and `#screen`
give copies of its rows.  Input, layouts, and themes are Ruby only.

Measured with `bench/term_bench.rb 5` (2026-10-31, the Mac container:
i9-9880H under Docker's Linux VM, Ruby 4.0.9; CPU time of one thread, the
stacks alternating within each of 5 rounds, medians).  Screens come from a
VT holding an `ls -la --color` style listing; "REPL refresh" is one line
arriving: VT#feed, VT#draw of the changed rows, the frame, and copy_from.
"Ruby VT, C grid" is mb-term before the C VT (term-2).

| VT feed, 4 KB pieces | bytes | Ruby MB/s | C MB/s | Ruby/C | Ruby +YJIT MB/s | C +YJIT MB/s | Ruby/C +YJIT |
|---|---|---|---|---|---|---|---|
| Pry transcript | 1051250 | 1.3 | 135.5 | 105x | 1.6 | 124.5 | 76x |
| ls -la burst | 1415182 | 3.9 | 75.6 | 20x | 5.6 | 75.8 | 14x |
| full-screen redraws 236x80 | 1402989 | 0.6 | 141.6 | 225x | 0.7 | 118.5 | 161x |

| µs per call, YJIT | size | Ruby | Ruby VT, C grid | C | Ruby/C | (Ruby VT, C grid)/C | frame bytes |
|---|---|---|---|---|---|---|---|
| frame, every cell | 80x24 | 331.3 | 13.1 | 12.2 | 27.2x | 1.1x | 2297 |
| frame, every cell | 120x40 | 746.5 | 16.8 | 18.0 | 41.5x | 0.9x | 5377 |
| frame, every cell | 236x80 | 2909.8 | 57.2 | 62.4 | 46.6x | 0.9x | 19968 |
| frame, 3 cells typed | 80x24 | 234.5 | 5.4 | 5.4 | 43.1x | 1.0x | 31 |
| frame, 3 cells typed | 120x40 | 572.0 | 13.3 | 13.1 | 43.7x | 1.0x | 31 |
| frame, 3 cells typed | 236x80 | 2433.5 | 51.1 | 51.4 | 47.3x | 1.0x | 31 |
| frame, one line scrolled in | 80x24 | 444.1 | 14.7 | 15.1 | 29.3x | 1.0x | 1590 |
| frame, one line scrolled in | 120x40 | 895.1 | 29.9 | 29.7 | 30.2x | 1.0x | 2632 |
| frame, one line scrolled in | 236x80 | 3408.5 | 85.6 | 86.2 | 39.5x | 1.0x | 5159 |
| lines (truecolor) | 80x24 | 98.2 | 11.8 | 10.1 | 9.7x | 1.2x |  |
| lines (truecolor) | 120x40 | 216.8 | 27.8 | 21.1 | 10.3x | 1.3x |  |
| lines (truecolor) | 236x80 | 796.2 | 92.5 | 81.3 | 9.8x | 1.1x |  |
| VT#draw, every row | 80x24 | 568.2 | 72.7 | 7.4 | 76.9x | 9.8x |  |
| VT#draw, every row | 120x40 | 1403.6 | 148.3 | 15.0 | 93.6x | 9.9x |  |
| VT#draw, every row | 236x80 | 5350.8 | 438.3 | 54.9 | 97.5x | 8.0x |  |
| REPL refresh (feed + draw + frame + copy) | 80x24 | 1052.3 | 112.3 | 22.0 | 47.9x | 5.1x |  |
| REPL refresh (feed + draw + frame + copy) | 120x40 | 2248.5 | 218.3 | 42.4 | 53.0x | 5.2x |  |
| REPL refresh (feed + draw + frame + copy) | 236x80 | 9748.5 | 579.5 | 154.2 | 63.2x | 3.8x |  |

Without YJIT (same run, plain Ruby): VT#draw of every row 6.2 / 14.6 /
60.0 µs in C vs 169 / 373 / 1196 µs for the Ruby VT into the C grid
(20-27x), a REPL refresh 18 / 42 / 151 µs vs 256 / 530 / 1432 µs (9-14x).

Reading it:

- Frame encoding in C is 27-69x faster than Ruby; a whole 236x80 screen
  is 57 µs in C and 2.9-3.9 ms in Ruby.  Scanning for changed cells is
  most of the cost of a small change (3 typed cells: 51 µs in C, 2.4-3.0
  ms in Ruby at 236x80), so the frame cost tracks the screen size, not
  the change.
- The C VT reads 76-142 MB/s (a 236x80 truecolor repaint, ~70 KB, in
  about 0.6 ms; the Ruby VT took 100 ms), 14-225x the Ruby VT; colored
  listings are the slowest (75 MB/s: a scrolled line's row is trimmed
  into the scrollback and a fresh one made).  With both in C, a REPL
  refresh at 236x80 is 154 µs, mostly the frame (86 µs) and the redraw
  of every row after a scroll (55 µs): 4-14x faster than the Ruby VT
  with the C grid.
- In mb-sound's tiled screen (`bin/ui_demo.rb --tiles -s 20 --size
  45x120`, "Last Stop", YJIT, alternating runs, realtime with NullOutput,
  so the wall-clock numbers depend on the machine's load): painter CPU
  per refresh p50 0.51 / 0.95 ms with the C grid and plot kernels vs 3.83 /
  3.76 ms with `MB_SOUND_PLOT=ruby` (p99 2.3 / 4.2 vs 9.5 / 9.6 ms);
  painter GVL holds over 2 ms 40 / 70 vs 1185 / 967 in 20 s.  That
  comparison includes mb-sound's plot kernels, which stay in mb-sound.
- A REPL flood in the same screen (`bin/ui_demo.rb --tiles --flood 20000
  -s 18`: Pry printing 20 000 lines, 1.57 MB, into the pane; 2026-10-31,
  3 alternating runs each): the pty reader's CPU was 36-59 ms with the C
  VT vs 163-193 ms with `MB_TERM_NATIVE=0`; Pry's printing sets the pace
  (25 000-32 000 lines a second either way).

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
the program's modes like scroll regions).  The VT itself is no longer
the limit for full-screen programs (the C VT reads 120-140 MB/s of
repaints; above).

## Running the specs

The gem has its own Gemfile and lockfile, and its specs run on their own
(no mb-sound): from this directory, `bundle install` once, then `bundle
exec rake compile` (the C extension) and `bundle exec rspec`; or `bundle
exec rake spec:gems` from mb-sound's root (which builds fast_term with
mb-sound's extensions and runs the specs under this directory's bundle).  `spec/boundary_spec.rb`
checks that the code reads only its own constants and Ruby's, requires
only itself and the standard library, and loads in a Ruby without
mb-sound or Bundler.
