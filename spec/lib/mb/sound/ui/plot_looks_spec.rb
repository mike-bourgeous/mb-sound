require_relative '../../../../support/ui_helpers'

# Plot pane looks (ux-1 r3 item 4): Braille by default for short or wide
# panes, a look per pane cycled with ui.look and kept in the layout.
RSpec.describe('UI plot pane looks', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  it 'picks Braille for short or wide panes and quadrants for tall narrow ones' do
    expect(ui::Panes::Scope.auto_look(46, 8)).to eq(:scope)
    expect(ui::Panes::Scope.auto_look(30, 5)).to eq(:scope)
    expect(ui::Panes::Scope.auto_look(200, 40)).to eq(:scope)
    expect(ui::Panes::Scope.auto_look(40, 30)).to eq(:quad)
  end

  it 'draws a short scope in Braille by default' do
    pane = ui::Panes::Scope.new
    text = ->(look) {
      grid = MB::Sound::Plot::Text::NativeCells.new(40, 6)
      pane.draw(ui::Canvas.new(grid, 0, 0, 40, 6), ui_fake_snapshot, {}, look: look)
      grid.to_text(:none)
    }
    expect(text.(nil)).to match(/[⠁-⣿]/)
    expect(text.(:quad)).not_to match(/[⠁-⣿]/)
  end

  it 'cycles the focused plot pane\'s look and keeps it in the layout' do
    term = UIHelpers::FakeTerminal.new(40, 120)
    tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:tiles), input: term.slave, output: term.slave, repl: :none, probe: false,
                          size: [40, 120], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                          keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    tiles.start(thread: false)
    tiles.refresh(0.0)
    tiles.focus(:scope)
    expect(tiles.look).to eq(:quad) # (after :scope, which :auto picked)
    tiles.refresh(0.0)
    expect(tiles.look).to eq(:blocks)
    expect(tiles.look(:scope)).to eq(:scope)
    expect(tiles.tiler.layout.to_ruby).to include('pane :scope, height: 8, look: :scope')
    expect { tiles.look(:nope) }.to raise_error(ArgumentError, /Unknown look :nope/)
    expect { tiles.look(pane: :tracks) }.to raise_error(ArgumentError, /isn't a plot pane/)
  ensure
    tiles&.stop
    term&.close
  end
end
