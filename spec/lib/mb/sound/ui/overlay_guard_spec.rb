require_relative '../../../../support/ui_helpers'

# No pane paints over an overlay (ui-fix-3): the scope and spectrum once
# wrote their own terminal bytes after the screen's frame, so their traces
# and axes covered the `?` keys overlay.  Every pane now draws into the one
# grid, and the overlays are painted into it after the panes.  For every
# pane kind (the plot panes in particular), with moving snapshots: the
# terminal shows exactly the screen's grid on every frame, the overlay's box
# stays the same while frames paint under it, and after Esc the pane shows
# what a fresh screen shows.  The band too (the same direct-write path).
RSpec.describe('UI overlays over every pane kind', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  after do
    @screens&.each { |tiles, term| tiles.stop; term.close }
  end

  # A console-less screen of +name+ alone, its snapshots moving with @k.
  def screen_of(name)
    term = UIHelpers::FakeTerminal.new(30, 100)
    layout = MB::Term::Viewports.layout(:"guard_#{name}") { pane name }
    tiles = ui::Tiles.new(layout: layout, input: term.slave, output: term.slave, repl: :none, probe: false, size: [30, 100],
                          clock: -> { @k.to_f }, source: -> { ui_fake_snapshot(t: @k * 0.04, seq: @k + 1, scope_phase: @k * 0.13) },
                          keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    (@screens ||= []) << [tiles, term]
    tiles.start(thread: false)
    [tiles, term]
  end

  # Paints frame +k+ (a second apart, so every pane is due) and waits
  # until the terminal has read it: a status query after the frame, whose
  # answer comes once the terminal got that far (a sync mark, no quiet
  # period; nothing else reads the screen's input without its threads).
  def paint(tiles, term, k)
    @k = k
    tiles.refresh(k.to_f)
    term.slave.write("\e[5n")
    got = +''
    until got.end_with?("\e[0n")
      raise "#{tiles.layout_name}: the terminal didn't answer after frame #{k}" unless IO.select([term.slave], nil, nil, 5)
      got << term.slave.read_nonblock(64)
    end
  end

  def grid_lines(tiles) = tiles.instance_variable_get(:@grid).to_text(:none).lines.map(&:rstrip)
  def term_lines(term) = term.lines.map(&:rstrip)

  # The terminal shows the grid, cell for cell (nothing reached it around
  # the grid's frame).
  def expect_grid_shown(tiles, term, what)
    t = term_lines(term)
    g = grid_lines(tiles)
    bad = t.each_index.reject { |y| t[y] == g[y].to_s }
    expect(bad).to eq([]), "#{what}: terminal rows #{bad.first(5).inspect} differ from the grid, e.g.\n  term: #{t[bad[0]].inspect}\n  grid: #{g[bad[0]].to_s.inspect}" unless bad.empty?
  end

  # The key overlay's box as rows of text, from the terminal.
  def overlay_box(term)
    lines = term.lines
    y0 = lines.index { |l| l.include?('keys (Esc closes') }
    return nil unless y0
    x0 = lines[y0].index('┌') || lines[y0].index('+')
    x1 = lines[y0].rindex('┐') || lines[y0].rindex('+')
    y1 = (y0 + 1...lines.length).find { |y| lines[y][x0] == '└' || lines[y][x0] == '+' }
    lines[y0..y1].map { |l| l[x0..x1] }
  end

  def pane_rows(tiles, term, name)
    r = tiles.chrome.frames[name]&.inner || tiles.tiler.placed.find { |p| p.name == name }.rect
    term.lines[r.y, r.h].map { |l| l[r.x, r.w].to_s.rstrip }
  end

  MB::Sound::UI.panes.each_key do |name|
    it "keeps the key overlay, NAV, and a temporary pane on top of a #{name} pane, which resumes after Esc" do
      tiles, term = screen_of(name)
      # The same frames without the overlay, for what the pane should show
      # after Esc (stateful panes like the load sparkline included)
      ref, ref_term = screen_of(name)
      paint(tiles, term, 0)
      expect_grid_shown(tiles, term, "#{name} frame 0")

      # The ? overlay over the pane while frames paint under it
      tiles.key_help(true)
      paint(tiles, term, 1)
      box = overlay_box(term)
      expect(box).not_to be_nil, "#{name}: no overlay"
      expect(box.join("\n")).to include('Esc closes', 'Panes')
      2.upto(4) do |k|
        paint(tiles, term, k)
        expect_grid_shown(tiles, term, "#{name} overlay frame #{k}")
        expect(overlay_box(term)).to eq(box), "#{name}: the overlay changed at frame #{k}"
      end

      # Esc: the pane comes back as the screen without the overlay shows it
      tiles.key_help(false)
      paint(tiles, term, 5)
      expect_grid_shown(tiles, term, "#{name} after Esc")
      expect(term.text).not_to include('Esc closes;')
      0.upto(5) { |k| paint(ref, ref_term, k) }
      got = pane_rows(tiles, term, name)
      want = pane_rows(ref, ref_term, name)
      expect(got).to eq(want), "#{name} didn't resume: #{got.inspect} vs #{want.inspect}"

      # NAV (its badges and status are painted after the panes)
      tiles.router.mode = :nav
      6.upto(7) do |k|
        paint(tiles, term, k)
        expect_grid_shown(tiles, term, "#{name} NAV frame #{k}")
      end
      tiles.router.mode = :play

      # A temporary pane beside it (a plot pane, or the messages for a plot)
      kind = %i[scope spectrum].include?(name) ? :messages : :spectrum
      close = tiles.plot_pane(kind, height: 8)
      expect(close).not_to be_nil
      8.upto(9) do |k|
        paint(tiles, term, k)
        expect_grid_shown(tiles, term, "#{name} with a temporary #{kind} frame #{k}")
      end
      close.call
      paint(tiles, term, 10)
      expect_grid_shown(tiles, term, "#{name} after the temporary #{kind}")
      expect(tiles.failures).to eq({})
    end
  end

  it 'shows the band\'s grid exactly, plot panes included, frame after frame' do
    %i[band deck mini].each do |layout|
      k = 0
      band, io = ui_fake_band(layout) { ui_fake_snapshot(t: k * 0.04, seq: k + 1, scope_phase: k * 0.13) }
      band.start(thread: false)
      band.plot_pane(:spectrum) if layout == :mini
      screen = MB::Term::Screen.new(30, 120)
      6.times do |i|
        k = i
        band.refresh(i.to_f)
        screen << io.string
        io.truncate(0)
        io.rewind
        expect(screen.lines.first(band.height).map(&:rstrip)).to eq(band.to_text.lines.map(&:rstrip).first(band.height)), "#{layout} frame #{i}"
      end
      expect(band.to_text).to match(/[⠁-⣿]/) # (a trace in the grid)
      expect(band.failures).to eq({})
    end
  end
end
