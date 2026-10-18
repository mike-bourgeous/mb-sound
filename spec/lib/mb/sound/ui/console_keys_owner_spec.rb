require_relative '../../../../support/ui_helpers'

# Ctrl-] read by a screen's own Pry thread (Tiles repl: :thread) acts on
# that screen (ux-r4-panes): with the tiles hidden (Ctrl-Z), Ctrl-] is
# relayed to the REPL's pty, where Reline's ConsoleKeys binding used to open
# a second tiled screen on the real terminal (random-walk specs drew one
# over the spec output now and then).
RSpec.describe('UI ConsoleKeys with a screen\'s own Pry', :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
  end

  it 'brings its own hidden screen back in NAV instead of opening one on the real terminal' do
    MB::Sound::UI::ConsoleKeys.install
    @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
    expect(@term.wait_for('t> ')).to eq(true)
    expect(MB::Sound::UI).not_to receive(:show)
    @term.write("\x1a") # Ctrl-Z: hidden, the pty relayed
    expect(wait_until { @tiles.hidden? }).to eq(true)
    @term.write("\x1d") # reaches Reline in the pane's Pry
    expect(wait_until { !@tiles.hidden? && @tiles.router.mode == :nav }).to eq(true), @term.text
    expect(@tiles.mode_problems).to eq([])
  end
end
