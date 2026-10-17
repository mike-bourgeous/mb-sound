require_relative '../../../../support/ui_helpers'

# Plots while a terminal UI is up (ux-1 bug 3): `vis` and play's plot go to
# a scope or spectrum pane of the screen, never over it.
RSpec.describe('UI plot panes', :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
  end

  it 'draws the spectrum pane from scope samples, with note names' do
    band, io = ui_fake_band(:mini)
    band.start(thread: false)
    restore = band.plot_pane(:spectrum)
    expect(band.layout.pane_names).to eq(%i[transport form spectrum])
    band.refresh(0.0)
    expect(band.failures).to be_empty
    expect(io.string).to include('C5', 'frequency')
    restore.call
    expect(band.layout.pane_names).to eq(%i[transport form])
    expect(band.plot_pane(:transport)).to be_nil # already shown
  end

  it 'puts a scope slot below the REPL for a plot, keeps the focus, and takes it out again' do
    @tiles, @term = ui_tiles(:keys, source: -> { ui_fake_snapshot })
    expect(@term.wait_for('t> ')).to eq(true)
    @tiles.keys(false)
    restore = @tiles.plot_pane(:scope)
    expect(@tiles.tiler.layout.panes).to include(:scope)
    expect(@tiles.tiler.focus).to eq(:repl)
    expect(@tiles.tiler.rects[:scope].h).to eq(10)
    restore.call
    expect(@tiles.tiler.layout.panes).not_to include(:scope)
    expect(@tiles.plot_pane(:meters)).to be_nil
  end

  it 'routes visualize to the screen: waits for a playback, or returns at once for the console' do
    @tiles, @term = ui_tiles(:keys, source: -> { ui_fake_snapshot })
    expect(@term.wait_for('t> ')).to eq(true)
    calls = 0
    r = MB::Sound.send(:visualize_in_ui, @tiles, spectrum: true, stop: -> { (calls += 1) > 2 })
    expect(r).to eq(pane: :spectrum)
    expect(calls).to eq(3)
    expect(@tiles.tiler.layout.panes).not_to include(:spectrum)

    expect { r = MB::Sound.send(:visualize_in_ui, @tiles, spectrum: false, stop: nil) }.to output(/scope pane shows the mix/).to_stdout
    expect(@tiles.tiler.layout.panes).to include(:scope)
  end
end
