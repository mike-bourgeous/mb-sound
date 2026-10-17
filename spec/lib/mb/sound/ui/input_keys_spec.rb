require_relative '../../../../support/ui_helpers'

# Keys around the REPL (ux-1 round 3 items 11, 15, 16, 17): Ctrl-W window
# keys with pass-through, direct scrolling that never takes a key the
# user's inputrc binds, Reline's own PgUp history search, ui.bind.
RSpec.describe('UI REPL keys', :aggregate_failures) do
  let(:keys) { MB::Sound::UI::Keys }
  let(:rk) { MB::Sound::UI::Input::RelineKeys }
  let(:key) { MB::Sound::UI::Input::Key }

  after do
    @tiles&.stop
    @term&.close
    keys.user.each_value { |m| m.entries.each { |b| m.off(b.keys) } }
    keys.rebuild
  end

  def config_from(text)
    path = tmp_path('inputrc')
    File.write(path, text)
    Reline::Config.new.tap { |c| c.read(path) }
  end

  it "skips default REPL keys the user's inputrc binds, in any byte form" do
    plain = config_from("# nothing\n")
    expect(rk.user_bound?(key.of(:page_up, :alt), config: plain)).to eq(false)
    taken = config_from(%("\\e[5;3~": history-search-backward\n))
    expect(rk.user_bound?(key.of(:page_up, :alt), config: taken)).to eq(true)
    expect(rk.user_bound?(key.of(:page_down, :alt), config: taken)).to eq(false)
    esc_form = config_from(%("\\e\\e[6~": history-search-forward\n))
    expect(rk.user_bound?(key.of(:page_down, :alt), config: esc_form)).to eq(true)

    map = keys.repl_keymap(config: taken)
    expect(map.bound?(key.of(:page_up, :alt))).to eq(false)
    expect(map.bound?(key.of(:page_down, :alt))).to eq(true)
    expect(keys.skipped.map(&:chord)).to eq([[:page_up, [:alt]]])
  ensure
    keys.instance_variable_set(:@repl_keymap, nil)
  end

  it "adds the IDE editing keys as Reline defaults, so an inputrc binding of the same keys wins" do
    c = Reline::Config.new
    expect(rk.install_editing_keys(config: c, erase: "\x7f")).to eq(['Ctrl-Backspace', 'Ctrl-Delete', 'Ctrl-Shift-Delete'])
    expect(c.key_bindings.get("\x08".bytes)).to eq(:ed_delete_prev_word)
    expect(c.key_bindings.get("\e[3;5~".bytes)).to eq(:em_delete_next_word)
    expect(c.key_bindings.get("\e[3;6~".bytes)).to eq(:ed_kill_line)
    c.read(StringIO.new(%("\\C-h": backward-delete-char\n)))
    expect(c.key_bindings.get("\x08".bytes)).to eq(:backward_delete_char)
    # A terminal whose Backspace sends ^H keeps it
    c2 = Reline::Config.new
    expect(rk.install_editing_keys(config: c2, erase: "\x08")).not_to include('Ctrl-Backspace')
  end

  it 'scrolls the REPL with Alt-PgUp without NAV, typing back to live, and leaves PgUp to Reline (history search)' do
    @tiles, @term = ui_tiles(:tiles)
    expect(@term.wait_for('t> ')).to eq(true)
    @term.type("pry_instance.output.puts((0...80).map { |i| \"row \#{i}\" })\r")
    expect(@term.wait_for('row 79')).to eq(true)
    expect(@term.wait_for(/lines of output: Alt-PgUp/)).to eq(true), @term.text
    @term.write("\e[5;3~")
    expect(wait_until { @tiles.scroll > 0 }).to eq(true)
    expect(@tiles.router.mode).to eq(:repl)
    expect(@term.wait_for('lines up (typing: live)')).to eq(true)
    @term.write("\e[6;3~")
    expect(wait_until { @tiles.scroll == 0 }).to eq(true)
    @term.write("\e[5;3~")
    expect(wait_until { @tiles.scroll > 0 }).to eq(true)
    @term.type('4')
    expect(wait_until { @tiles.scroll == 0 }).to eq(true)
    @term.write("\x15")
    @term.type("40 + 2\r")
    expect(@term.wait_for('=> 42')).to eq(true)
    @term.type('40')
    @term.write("\e[5~") # PgUp: Reline's history search backward
    expect(@term.wait_for('t> 40 + 2')).to eq(true), @term.text
    @term.write("\x15")
  end

  it 'moves between panes with Ctrl-W then a window key, and passes other keys through to the REPL (Ctrl-W deletes a word)' do
    @tiles, @term = ui_tiles(:tiles)
    expect(@term.wait_for('t> ')).to eq(true)
    @term.write("\x17")
    expect(@term.wait_for('Ctrl-W: h j k l')).to eq(true)
    @term.write('l')
    expect(wait_until { @tiles.tiler.focus != :repl }).to eq(true)
    expect(@tiles.router.mode).to eq(:nav) # (another pane: its keys, NAV's)
    @term.write("\x17p") # back to the last pane: the REPL
    expect(wait_until { @tiles.tiler.focus == :repl && @tiles.router.mode == :repl }).to eq(true)
    @term.type('6 * 7 junk')
    @term.write("\x17") # Ctrl-W then a key that isn't a window key: word deleted, the key typed
    @term.write("\r")
    expect(@term.wait_for('=> 42')).to eq(true), @term.text
    expect(@tiles.mode_problems).to eq([])
    @tiles.router.window_prefix = false
    @term.type('7 * 6 junk')
    @term.write("\x17\r")
    expect(@term.wait_for('=> 42', timeout: 4)).to eq(true)
  end

  it 'binds keys with ui.bind (Ctrl-K: KEYS, as an option) and takes them away with ui.unbind' do
    note = keys.bind(['k', :ctrl], :keys)
    expect(note).to include('Ctrl-K -> keys (repl)')
    expect(keys.repl_keymap[key.of('k', :ctrl)].name).to eq(:keys)
    expect { keys.bind([']', :ctrl], :zoom) }.to raise_error(ArgumentError, /NAV key/)
    @tiles, @term = ui_tiles(:tiles)
    expect(@term.wait_for('t> ')).to eq(true)
    @term.write("\x0b")
    expect(wait_until { @tiles.router.mode == :grab }).to eq(true)
    @term.write("\eOQ")
    expect(wait_until { @tiles.router.mode == :repl }).to eq(true)
    keys.unbind(['k', :ctrl])
    expect(keys.repl_keymap[key.of('k', :ctrl)]).to be_nil
    @term.type('6 * 7 junk')
    @term.write("\e[D" * 5 + "\x0b\r") # Ctrl-K: Reline's kill to the end again
    expect(@term.wait_for('=> 42')).to eq(true), @term.text
    expect(MB::Sound::UI::Tiles.key_table(:repl).join("\n")).to include('Alt-PgUp')
  end
end
