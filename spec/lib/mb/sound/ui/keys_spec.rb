require 'mb/sound'

# The key table (ux-1 round 3, pattern C): every binding is described, so
# the ? overlay and help :ui list it, and every UI key read in the REPL
# says what it does outside the tiles.
RSpec.describe(MB::Sound::UI::Keys, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:maps) {
    [ui::Input::Router::NAV, ui::Keys::NAV_EXTRA, ui::Keys::REPL_DEFAULTS, ui::Keyboard::KEYMAP,
     ui::Keys::SONG_SCREEN, ui::Keys::SYNTH_SCREEN]
  }

  it 'describes every binding of every keymap, so the overlay and help list it' do
    maps.each do |m|
      m.entries.each { |b| expect(b.help).to be_a(String), "#{m.name}: #{b.chord.inspect} -> #{b.action} has no help" }
      expect(m.help_groups).not_to be_empty
    end
    table = ui::Tiles.key_table.join("\n")
    %w[Panes Console Modes REPL Keyboard].each { |g| expect(table).to include("#{g}:") }
    expect(ui::Tiles::KEY_HELP.keys).to include(:repl, :nav, :once, :grab, :step, :elsewhere)
  end

  it "keeps every pane's jump letter clear of NAV's keys and the others' (ux-r4, ux-r4b)" do
    declared = ObjectSpace.each_object(Class).select { |c| c < ui::Pane && c.name && c.jump }.to_h { |c| [ui::PaneKeys.kind_of(c.allocate), c.jump] }
    expect(ui::Keys.check_jumps(declared)).to eq([])
    expect(ui::Keys::JUMPS).to eq(repl: 'i', keyboard: 'k', tracks: 't', meters: 'e')
    expect(ui::Keys.reserved_letters).to include('p', 's', 'v', 'z', 'x', 'm', 'f', 'g', 'G', 'u', 'n', 'y')
    # (h j l are free since ux-r4b: arrows move the focus; K is free too)
    expect(ui::Keys.reserved_letters).not_to include('h', 'j', 'l', 'i', 'k', 'K', 't', 'e', 'a', 'r', 'b')
    # What the check catches
    expect(ui::Keys.check_jumps(clips: 'z').join).to include(":clips's jump \"z\" is a NAV key")
    expect(ui::Keys.check_jumps(clips: 'a', racks: 'a').join).to include('jump "a" is claimed by :clips and :racks')
    expect(ui::Keys.check_jumps(clips: 't').join).to include('claimed by :tracks and :clips')
  end

  it 'says what each UI key read in the REPL does in the band and without a UI (none dropped silently, item 18)' do
    names = ui::Keys::ELSEWHERE.map(&:first).join(' ')
    repl_keys = ['Ctrl-]', 'F2', 'Ctrl-W', 'Alt-PgUp', 'Ctrl-BkSp', 'Ctrl-Del', 'Ctrl-S-Del', 'Ctrl-C', 'Ctrl-Z']
    repl_keys.each { |k| expect(names).to include(k) }
    ui::Keys::REPL_DEFAULTS.entries.each { |b| expect(names).to include(ui::Input::Keymap.chord_name(b.chord)) }
    # Ctrl-] and F2 are Reline bindings there (UI::ConsoleKeys)
    seqs = ui::ConsoleKeys::BINDINGS.to_h { |s, f| [f, s] }
    expect(seqs[:mb_sound_ui_nav]).to include("\x1d")
    expect(seqs[:mb_sound_ui_keys]).to include("\eOQ", "\e[12~")
  end

  it 'routes every console-side binding to an editor method that exists' do
    ui::ConsoleKeys.install
    ui::ConsoleKeys::BINDINGS.each { |_, f| expect(Reline::LineEditor.private_method_defined?(f)).to eq(true), f.to_s }
  end
end
