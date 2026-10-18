require_relative '../../../../support/ui_helpers'

# Pane-local keys (ux-1 round 3 item 36): a focused pane's keymap acts in
# NAV before NAV's, and the ? overlay lists it.
RSpec.describe(MB::Sound::UI::PaneKeys, :aggregate_failures) do
  let(:pane_class) {
    Class.new(MB::Sound::UI::Pane) {
      keys do
        group 'Counter'
        on '+', :bump, 1, help: 'count up'
        on 'h', :bump, -1, help: 'count down (shadows NAV h here)'
      end

      def initialize = super(:counter, rate: 30, height: 4, title: 'counter')

      def key_bump(state, by)
        state[:n] = state[:n].to_i + by
        "count #{state[:n]}"
      end

      def draw_body(c, _s, state) = c.puts ["n=#{state[:n].to_i}", :key]
    }
  }

  after do
    @tiles&.stop
    @term&.close
  end

  it 'runs the focused pane\'s keys in NAV, flashes their result, and lists them in the overlay' do
    panes = MB::Sound::UI.panes.merge(counter: pane_class.new)
    @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, panes: panes)
    expect(@term.wait_for('t> ')).to eq(true)
    @tiles.show(:counter, at: :queue)
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type((@tiles.tiler.numbered.index(:counter) + 1).to_s)
    expect(wait_until { @tiles.tiler.focus == :counter }).to eq(true)
    @term.type('++h+')
    expect(@term.wait_for('n=2')).to eq(true), @term.text
    expect(@term.wait_for('count 2')).to eq(true), @term.lines.last
    expect(@tiles.tiler.focus).to eq(:counter) # (h was the pane's)
    @term.type('?')
    expect(@term.wait_for('Counter (counter)')).to eq(true), @term.text
    expect(@term.text).to include('count up')
    @term.write("\e")
    expect(wait_until { !@tiles.key_help? }).to eq(true)
    # Another pane focused: NAV's h again
    @term.type((@tiles.tiler.numbered.index(:repl) + 1).to_s)
    @term.type('+')
    expect(@term.wait_for('+: not a NAV key')).to eq(true)
  end
end

# A pane's own mode (ux-r4 item 1): NAV Enter goes into the focused pane
# (the REPL, KEYS, or a pane's mode keys until Esc), jump letters focus and
# go in, and the mode follows the focus.
RSpec.describe('UI pane modes and jumps', :aggregate_failures) do
  let(:pane_class) {
    Class.new(MB::Sound::UI::Pane) {
      jump 'a'
      keys do
        group 'Grid'
        on 'R', :reset, help: 'cursor home'
      end
      mode_keys do
        group 'Grid'
        on :up, :move, -1, help: 'move the cursor', label: 'Up Down j k'
        on :down, :move, 1, help: 'move the cursor', label: ''
        on 'j', :move, 1, help: 'move the cursor', label: ''
        on 'k', :move, -1, help: 'move the cursor', label: ''
        on :enter, :pick, help: 'pick the row'
      end

      def initialize = super(:grid, rate: 30, height: 6, title: 'grid')

      def key_move(state, by)
        state[:row] = state[:row].to_i + by
        nil
      end

      def key_reset(state) = (state[:row] = 0) && 'home'
      def key_pick(state) = "picked #{state[:row].to_i}"

      def draw_body(c, _s, state) = c.puts ["row=#{state[:row].to_i}#{state[:mode] ? ' [in]' : ''}", :key]
    }
  }

  after do
    @tiles&.stop
    @term&.close
  end

  it 'enters a pane with Enter or its letter, routes its keys there, and leaves with Esc, Ctrl-], or a focus change' do
    panes = MB::Sound::UI.panes.merge(grid: pane_class.new)
    @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, panes: panes)
    expect(@term.wait_for('t> ')).to eq(true)
    @tiles.show(:grid, at: :queue)
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    n = @tiles.tiler.numbered.index(:grid) + 1
    expect(@term.wait_for(" #{n} a ")).to eq(true), @term.text # (its letter beside its number in NAV)
    @term.type(n.to_s)
    expect(wait_until { @tiles.tiler.focus == :grid }).to eq(true)
    @term.write("\r")
    expect(wait_mode(@tiles, :pane)).to eq(true)
    expect(@term.lines.last).to start_with(' GRID ')
    expect(@tiles.router.mode).to eq(:pane)
    @term.write("\e[B\e[Bjk") # Down Down j k: the pane's keys, not NAV's (1 + 1 + 1 - 1)
    expect(@term.wait_for('row=2 [in]')).to eq(true), @term.text
    expect(@tiles.tiler.focus).to eq(:grid)
    @term.write("\r")
    expect(@term.wait_for('picked 2')).to eq(true)
    @term.type('q')
    expect(@term.wait_for('not a key of this pane')).to eq(true)
    @term.type('R') # (the pane's NAV keys work in its mode too)
    expect(@term.wait_for('row=0 [in]')).to eq(true)
    @term.type('?')
    expect(@term.wait_for('pick the row')).to eq(true)
    @term.write("\e")
    expect(wait_mode(@tiles, :pane)).to eq(true)
    expect(@tiles.mode_problems).to eq([])
    # Esc: NAV (the cursor goes), Ctrl-]: back in
    @term.write("\e")
    expect(wait_mode(@tiles, :nav)).to eq(true)
    expect(@term.wait_for(/row=0(?! \[in\])/)).to eq(true)
    @term.write("\x1d")
    expect(wait_mode(@tiles, :pane)).to eq(true)
    # A focus change from Ruby ends the mode
    @tiles.focus(:tracks)
    expect(@tiles.router.mode).to eq(:nav)
    expect(@tiles.mode_problems).to eq([])
    # Ctrl-] from NAV now: the pane's mode isn't where the focus is, so NAV -> pane -> NAV
    # Jumps: a (the grid, in), t (tracks: no keys of its own, focused in NAV), i (the REPL)
    @term.type('a')
    expect(wait_settled(@tiles) { @tiles.router.mode == :pane && @tiles.tiler.focus == :grid }).to eq(true)
    @term.write("\e")
    expect(wait_mode(@tiles, :nav)).to eq(true) # (an Esc and a quick key would read as Alt-t)
    @term.type('t')
    expect(wait_until { @tiles.tiler.focus == :tracks }).to eq(true)
    expect(@tiles.router.mode).to eq(:nav)
    expect(@term.wait_for('no keys of its own')).to eq(true)
    @term.write("\r") # Enter on a pane without keys: stays in NAV
    expect(@tiles.router.mode).to eq(:nav)
    @term.type('i')
    expect(wait_mode(@tiles, :repl)).to eq(true)
    expect(@tiles.tiler.focus).to eq(:repl)
    # K: the keyboard, put in and played
    @term.write("\x1d")
    expect(wait_mode(@tiles, :nav)).to eq(true)
    @term.type('K')
    expect(wait_mode(@tiles, :grab)).to eq(true)
    expect(@tiles.tiler.layout.panes).to include(:keyboard)
    @tiles.keys(false)
    # A jump to a pane that isn't there says how to show it
    @tiles.router.mode = :nav
    @tiles.jump(:spectrum)
    expect(@term.wait_for('no spectrum pane here')).to eq(true)
    expect(@tiles.mode_problems).to eq([])
  end

  it 'keeps the mode invariants through random keys with a pane that has a mode' do
    rng = Random.new(RSpec.configuration.seed)
    panes = MB::Sound::UI.panes.merge(grid: pane_class.new)
    @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, panes: panes)
    expect(@term.wait_for('t> ')).to eq(true)
    @tiles.show(:grid, at: :queue)
    steps = {
      nav: "\x1d", enter: "\r", esc: "\e", a: 'a', t: 't', i: 'i', down: "\e[B", k: 'k', tab: "\t", q: 'q', question: '?',
      digit: -> { rng.rand(1..7).to_s }, focus: -> { @tiles.focus(:tracks); nil }, enter_ruby: -> { @tiles.enter(:grid); nil },
      ctrl_w_l: "\x17l", f2: "\eOQ",
    }
    # (letters reach the REPL in REPL mode and Enter runs them: only ones
    # that are harmless as Ruby; `j` is a deprecated Kernel method)
    path = []
    40.times do
      name, key = steps.to_a.sample(random: rng)
      path << name
      key = key.call if key.respond_to?(:call)
      @term.write(key) if key
      @term.settle(quiet: 0.05)
      expect(@tiles.mode_problems).to eq([]), "#{path.join(' ')}: #{@tiles.mode_problems.inspect}"
    end
  end
end

# Script screens' key tables (ux-1 round 3 items 42, 43): keys through the
# Router's :play state, repeats acting like presses.
RSpec.describe('UI script screen keys', :aggregate_failures) do
  it 'sends song-screen actions to the script, a held key (legacy or kitty repeats) stepping each time, with hints from the table' do
    term = UIHelpers::FakeTerminal.new(30, 120)
    actions = []
    keys = []
    tiles = MB::Sound::UI::Tiles.new(layout: MB::Sound::UI.show_layouts[:show], input: term.slave, output: term.slave, repl: :none,
                                     probe: false, play_keys: MB::Sound::UI::Keys::SONG_SCREEN, on_action: ->(a) { actions << a.name },
                                     on_key: ->(k) { keys << k })
    tiles.start
    expect(term.wait_for('PLAY')).to eq(true)
    expect(term.text).to include('q Esc quit')
    term.write("\e[D\e[D\e[D") # Left held (legacy autorepeat)
    term.write("\e[1;1:1C\e[1;1:2C\e[1;1:2C\e[1;1:3C") # Right press, two repeats, release (kitty)
    term.write(']')
    term.write("\e[6~")
    term.write('x')
    expect(wait_until { actions.length >= 8 && keys.length >= 1 }).to eq(true), actions.inspect
    expect(actions).to eq(%i[bar_back bar_back bar_back bar_forward bar_forward bar_forward section_next scene_next])
    expect(keys.map(&:key)).to eq(['x'])
    term.write("\e")
    expect(wait_until { actions.last == :quit }).to eq(true)
    expect(tiles.router.state).to eq(:play)
  ensure
    tiles&.stop
    term&.close
  end
end
