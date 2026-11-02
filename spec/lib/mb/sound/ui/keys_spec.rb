require 'mb/sound'

# The key table (ux-1 round 3, pattern C): every binding is described, so
# the ? overlay and help :ui list it, and every UI key read in the REPL
# says what it does outside the tiles.
RSpec.describe(MB::Sound::UI::Keys, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:maps) {
    [MB::Term::Input::Router::NAV, ui::Keys::NAV_EXTRA, ui::Keys::REPL_DEFAULTS, ui::Keyboard::KEYMAP,
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

  # (inspector-nav-1; the maintainer, 2026-11-02: "Inspector help shows
  # "s f a o x" repeated as the key for all sections, and "n N Tab S-Tab"
  # as the row keys.  Should be s, then f, etc.")
  it 'names on each help line only the keys bound to what it says, in every keymap (panes, modes, NAV, the keyboard)' do
    km = MB::Term::Input::Keymap
    all = ObjectSpace.each_object(km).to_a
    all += ObjectSpace.each_object(Class).select { |c| c < ui::Pane }.flat_map { |c| [c.keymap, c.mode_keymap] }.compact
    all.uniq!
    expect(all.map(&:name)).to include(:inspector_mode, :nav)
    all.each do |m|
      docs = m.instance_variable_get(:@docs).map { |_, keys, help, _| [keys, help] }
      by_help = m.entries.group_by { |b| [b.group, b.help] }
      labels = m.entries.group_by { |b| [b.group, b.label] }
      m.help_groups.each do |group, lines|
        lines.each do |keys, help|
          next if docs.include?([keys, help])
          bs = by_help.find { |(g, h), _| h == help && (g || m.name.to_s.capitalize) == group }&.last
          expect(bs).not_to be_nil, "#{m.name}: #{keys}: #{help} has no binding"
          next unless bs
          allowed = bs.flat_map { |b|
            own = km.keys_name(b.keys).split
            # (a label names its bindings only where they all say this)
            whole = b.label && labels[[b.group, b.label]].all? { |o| o.help == help }
            whole ? own + b.label.split : own
          }
          expect(keys.split - allowed).to eq([]), "#{m.name}: #{keys.inspect} on #{help.inspect}: bound #{bs.map { |b| km.keys_name(b.keys) }.join(', ')}"
        end
      end
    end
    # The inspector's, as the maintainer asked: each section its own key
    rows = ui::Panes::Inspector.mode_keymap.help_groups.to_h.fetch('Inspector').to_h { |k, h| [h, k] }
    expect(rows.values_at(*rows.keys.grep(/\A(SOURCE|FILTER|AMP|MOD|FX):/))).to eq(%w[s f a o x])
    expect(rows['the next row (preview and params)']).to eq('n ] Tab')
    expect(rows['the previous row']).to eq('N [ S-Tab')
    # (a label shared by bindings that say one thing still stands for them)
    m = km.new(:t) { on :left, :back, help: 'back, forward', label: 'Left Right'; on :right, :fwd, help: 'back, forward', label: 'Left Right' }
    expect(m.help_groups).to eq([['T', [['Left Right', 'back, forward']]]])
  end

  it "keeps every pane's jump letter clear of NAV's keys and the others' (ux-r4, ux-r4b)" do
    declared = ObjectSpace.each_object(Class).select { |c| c < ui::Pane && c.name && c.jump }.to_h { |c| [ui::PaneKeys.kind_of(c.allocate), c.jump] }
    expect(ui::Keys.check_jumps(declared)).to eq([])
    expect(ui::Keys::JUMPS).to eq(repl: 'i', keyboard: 'k', tracks: 't', meters: 'e')
    expect(ui::Keys.reserved_letters).to include('p', 's', 'v', 'z', 'x', 'm', 'f', 'g', 'G', 'u', 'n', 'y')
    # (h j l are free since ux-r4b: arrows move the focus; K is NAV's KEYS
    # again since ui-api-1, as the docs say: panel round 2 K16/N7)
    expect(ui::Keys.reserved_letters).to include('K')
    expect(ui::Keys.reserved_letters).not_to include('h', 'j', 'l', 'i', 'k', 't', 'e', 'a', 'r', 'b')
    # What the check catches
    expect(ui::Keys.check_jumps(clips: 'z').join).to include(":clips's jump \"z\" is a NAV key")
    expect(ui::Keys.check_jumps(clips: 'a', racks: 'a').join).to include('jump "a" is claimed by :clips and :racks')
    expect(ui::Keys.check_jumps(clips: 't').join).to include('claimed by :tracks and :clips')
  end

  it 'says what each UI key read in the REPL does in the band and without a UI (none dropped silently, item 18)' do
    names = ui::Keys::ELSEWHERE.map(&:first).join(' ')
    repl_keys = ['Ctrl-]', 'F2', 'Ctrl-W', 'Alt-PgUp', 'Ctrl-BkSp', 'Ctrl-Del', 'Ctrl-S-Del', 'Ctrl-C', 'Ctrl-Z']
    repl_keys.each { |k| expect(names).to include(k) }
    ui::Keys::REPL_DEFAULTS.entries.each { |b| expect(names).to include(MB::Term::Input::Keymap.chord_name(b.chord)) }
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
