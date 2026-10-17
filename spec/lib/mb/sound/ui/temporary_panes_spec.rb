require_relative '../../../../support/ui_helpers'

# Temporary panes (plots, the messages pane) are reversible layout edits,
# and declared minimum heights hold (ux-1 r3 item 30: each `play` round trip
# with a temporary scope shrank the keyboard until it disappeared).
RSpec.describe('UI temporary panes and pane minimums', :aggregate_failures) do
  V = MB::Sound::UI::Viewports unless defined?(V)
  let(:ui) { MB::Sound::UI }
  let(:mins) { ->(name, axis) { axis == :rows ? ui.panes[name]&.min_height || (name == :repl ? 4 : nil) : nil } }

  def tiler(name, w, h)
    t = V::Tiler.new(ui.tile_layouts.fetch(name), w, h)
    t.mins = mins
    t.header_rule = h >= 24
    t
  end

  # Random edits that a person makes between temporary panes.
  def random_edit(t, rng)
    panes = t.layout.panes
    case rng.rand(5)
    when 0 then t.split(panes.sample(random: rng), %i[cols rows].sample(random: rng))
    when 1 then t.resize(panes.sample(random: rng), %i[left right up down].sample(random: rng), rng.rand(1..4))
    when 2 then t.close((panes - [:repl]).sample(random: rng)) if panes.length > 2
    when 3 then t.equalize(panes.sample(random: rng))
    else t.focus!(panes.sample(random: rng))
    end
  rescue V::Error
    nil
  end

  it 'gives the tree back exactly after any number of temporary panes, nested or not' do
    rng = Random.new(RSpec.configuration.seed)
    60.times do
      t = tiler(%i[tiles studio keys wall].sample(random: rng), rng.rand(80..240), rng.rand(24..80))
      rng.rand(0..4).times { random_edit(t, rng) }
      start = t.layout
      undo = t.instance_variable_get(:@undo).length
      kinds = (%i[scope spectrum messages] - start.panes).shuffle(random: rng).first(rng.rand(1..3))
      temps = kinds.map { |k| t.open_temporary(k, rng.rand(3..12), keep: %i[repl keyboard], fallback: :repl) }
      expect(t.layout.focus).to eq(start.focus) # (the focus stays)
      temps.reverse_each { |tmp| t.close_temporary(tmp) }
      expect(t.layout).to eq(start)
      expect(t.instance_variable_get(:@undo).length).to eq(undo) # (temporary panes are no undo steps)
    end
  end

  it 'keeps the keyboard\'s height through repeated plots (the ux-1 bug)' do
    t = tiler(:keys, 100, 29)
    h = t.rects[:keyboard].h
    6.times do
      tmp = t.open_temporary(:scope, 10, keep: %i[repl keyboard], fallback: :repl)
      expect(t.rects[:keyboard].h).to eq(h)
      t.close_temporary(tmp)
      expect(t.rects[:keyboard].h).to eq(h)
    end
  end

  it 'takes the rows from the largest flexible pane that is not the REPL or the keyboard' do
    t = tiler(:keys, 100, 29)
    tmp = t.open_temporary(:scope, 8, keep: %i[repl keyboard], fallback: :repl)
    # The tracks pane (flexible, beside the REPL) gives up its rows; the scope sits below it
    expect(t.rects[:scope].y).to eq(t.rects[:tracks].y + t.rects[:tracks].h + 1)
    expect(t.rects[:scope].h).to eq(8)
    t.close_temporary(tmp)
  end

  it 'only removes the pane when the tree changed meanwhile' do
    t = tiler(:tiles, 120, 40)
    tmp = t.open_temporary(:spectrum, 8, keep: %i[repl keyboard])
    t.split(:repl, :cols)
    t.close_temporary(tmp)
    expect(t.layout.panes).not_to include(:spectrum)
    expect(t.layout.panes).to include(:empty1)
  end

  it 'never places a pane under its declared minimum while the screen has room for every minimum' do
    rng = Random.new(RSpec.configuration.seed + 1)
    80.times do
      t = tiler(%i[tiles studio keys wall].sample(random: rng), rng.rand(80..240), rng.rand(22..80))
      rng.rand(0..3).times { random_edit(t, rng) }
      root = t.layout.root
      next if V.min_of(root, :rows, mins) > t.h # (the screen can't hold them all)
      t.placed.each do |p|
        next unless p.name
        least = mins.(p.name, :rows) || 1
        expect(p.rect.h).to be >= least, "#{p.name} #{p.rect} in #{t.layout.to_ruby} at #{t.w}x#{t.h}"
      end
    end
  end

  it 'gives a Tiles screen its tree back after play\'s temporary scopes, and a messages pane toggled on and off' do
    term = UIHelpers::FakeTerminal.new(30, 100)
    tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:keys), input: term.slave, output: term.slave, repl: :none, probe: false,
                          size: [30, 100], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                          keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    tiles.start(thread: false)
    start = tiles.tiler.layout
    kb = tiles.tiler.rects[:keyboard]
    5.times do
      close = tiles.plot_pane(:scope, height: 10)
      tiles.refresh(0.0)
      expect(tiles.to_text).to include('SCOPE')
      close.call
      tiles.refresh(0.0)
      expect(tiles.tiler.layout).to eq(start)
      expect(tiles.tiler.rects[:keyboard]).to eq(kb)
    end
    tiles.messages(true)
    expect(tiles.tiler.layout.panes).to include(:messages)
    tiles.messages(false)
    expect(tiles.tiler.layout).to eq(start)
  ensure
    tiles&.stop
    term&.close
  end
end
