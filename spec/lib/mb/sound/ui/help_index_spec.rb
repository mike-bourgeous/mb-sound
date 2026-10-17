require 'mb/sound/help'

# Help finds the terminal UI (ux-1 r3 item 35): every pane kind, layout,
# and ui method is reachable by `help <its name>`, generated from the UI's
# own registries, and a search that finds nothing suggests near names.
RSpec.describe(MB::Sound::UI::HelpIndex, :aggregate_failures) do
  def page(text) = MB::U.remove_ansi(MB::Sound::Help.page_for_text(text).to_s)

  it 'indexes panes, layouts, looks, keys, and ui methods' do
    kinds = described_class.entries.map(&:kind).uniq
    expect(kinds).to include(:pane, :layout, :look, :key, :ui_method)
    expect(described_class.search(/scope/i).map(&:label)).to include('pane scope', 'look scope', 'ui.look')
    expect(described_class.ui_methods.to_h[:split]).to start_with('Splits')
    described_class.ui_methods.each { |m, what| expect(what).not_to be_empty, "ui.#{m} has no doc comment" }
  end

  it 'finds every pane, layout, and ui method by help <its name>' do
    names = described_class.entries.select { |e| %i[pane layout ui_method].include?(e.kind) }
    names.each do |e|
      text = page(e.name)
      expect(text).to include(e.label), "help #{e.name} doesn't show #{e.label}:\n#{text.lines.first(8).join}"
    end
  end

  it 'finds the scope pane, its looks, and play\'s scope slot with help scope (the maintainer\'s miss)' do
    text = page('scope')
    expect(text).to include('Terminal UI', 'pane scope', 'look scope', 'ui.look')
  end

  it 'suggests near names and regex search when nothing matches' do
    text = page('scoep')
    expect(text).to include('Nothing matches', 'help scope', 'help /regex/')
  end
end
