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
