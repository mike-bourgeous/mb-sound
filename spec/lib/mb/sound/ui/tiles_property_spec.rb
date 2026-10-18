require_relative '../../../../support/ui_helpers'

# Property: whatever sequence of layout edits, layout switches, and
# terminal resizes a screen went through, every pane shows what a fresh
# screen with the same tree and size shows (ux-1 bug 1 was a pane body
# kept from an old placement; this rules out the whole class of state
# surviving a relayout).
RSpec.describe('UI::Tiles relayout property', :aggregate_failures) do
  after do
    [@a, @b].each { |t| t&.stop }
    [@ta, @tb].each { |t| t&.close }
  end

  # Text of each cell pane (not the REPL or the keyboard, not byte-writing
  # panes) by name.
  def pane_texts(tiles)
    text = tiles.to_text.lines.map(&:chomp)
    tiles.tiler.placed.each_with_object({}) do |p, h|
      next if p.name.nil? || p.name == :repl || p.name == :keyboard || p.tabs # (the keyboard shows the mode)
      pane = MB::Sound::UI.panes[p.name]
      next if pane&.bytes?
      r = p.rect
      h[p.name] = text[r.y, r.h].map { |l| l[r.x, r.w] }
    end
  end

  # Draws a frame now, as the painter's next one would (a relayout makes
  # it a full frame; test-speed-3: waiting for 0.1 s of quiet output, 18
  # times, took most of the example).
  def settle(tiles)
    tiles.refresh
  end

  it 'draws every pane as a fresh screen would after random edits' do
    rng = Random.new(RSpec.configuration.seed)
    snap = ui_fake_snapshot
    names = MB::Sound::UI.panes.keys - %i[keyboard]
    ops = [
      -> { @a.split(%i[cols rows].sample(random: rng), at: @a.tiler.layout.panes.sample(random: rng)) },
      -> {
        empty = @a.tiler.layout.panes.grep(/\Aempty/)
        free = names - @a.tiler.layout.panes
        @a.show(free.sample(random: rng), at: empty.sample(random: rng)) unless empty.empty? || free.empty?
      },
      -> { @a.close((@a.tiler.layout.panes - [:repl]).sample(random: rng)) },
      -> { @a.resize(%i[left right up down].sample(random: rng), rng.rand(1..5), name: @a.tiler.layout.panes.sample(random: rng)) },
      -> { @a.zoom(@a.tiler.layout.panes.sample(random: rng)) },
      -> { @a.undo },
      -> { @a.redo },
      -> { @a.layout(%i[tiles studio keys wall].sample(random: rng)) },
      -> { @ta.resize(rng.rand(24..40), rng.rand(90..140)) },
    ]
    # (One live REPL per process: Reline is global, so the edited screen
    # stops before the fresh one starts)
    3.times do |round|
      @a, @ta = ui_tiles(%i[tiles studio keys wall].sample(random: rng), source: -> { snap })
      expect(@ta.wait_for(/ (REPL|KEYS) /)).to eq(true)
      8.times do
        ops.sample(random: rng).call
        settle(@a) if rng.rand < 0.5 # some edits drawn, some only queued
      end
      settle(@a)
      layout = @a.tiler.layout
      rows, cols = @a.rows, @a.cols
      a = pane_texts(@a)
      @a.stop
      @ta.close
      @a = @ta = nil

      @b, @tb = ui_tiles(layout, rows: rows, cols: cols, source: -> { snap })
      expect(@tb.wait_for(/ (REPL|KEYS) /)).to eq(true)
      settle(@b)
      b = pane_texts(@b)
      expect(a.keys.sort).to eq(b.keys.sort), "round #{round}"
      a.each { |name, lines| expect(lines).to eq(b[name]), "round #{round}, pane #{name.inspect} (#{layout.to_ruby})" }
      @b.stop
      @tb.close
      @b = @tb = nil
    end
  end
end
