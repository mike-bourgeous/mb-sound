RSpec.describe(MB::Sound::UI::Input::Decoder, :aggregate_failures) do
  let(:d) { MB::Sound::UI::Input::Decoder.new }
  let(:key) { MB::Sound::UI::Input::Key }
  let(:input) { MB::Sound::UI::Input }

  def chords(events) = events.map { |e| e.is_a?(key) ? e.chord : e }

  it 'decodes text, controls, and Ctrl-] (the NAV key) with their bytes' do
    ev = d.feed("aZ中\r\t\x7f\x03\x1d")
    expect(chords(ev)).to eq([['a', []], ['Z', []], ['中', []], [:enter, []], [:tab, []], [:backspace, []], ['c', [:ctrl]], [']', [:ctrl]]])
    expect(ev.map(&:bytes).join.b).to eq("aZ中\r\t\x7f\x03\x1d".b)
  end

  it 'decodes cursor keys, modifiers, function keys, and SS3' do
    ev = d.feed("\e[A\e[1;2C\e[1;5D\e[3~\e[5;3~\e[15~\eOP\eOA\e[Z")
    expect(chords(ev)).to eq([[:up, []], [:right, [:shift]], [:left, [:ctrl]], [:delete, []], [:page_up, [:alt]], [:f5, []], [:f1, []], [:up, []], [:tab, [:shift]]])
    expect(ev[1].bytes).to eq("\e[1;2C".b)
  end

  it 'waits for the rest of a split sequence, and emits a lone ESC on flush' do
    expect(d.feed("\e")).to eq([])
    expect(d.pending?).to eq(true)
    expect(chords(d.feed('[B'))).to eq([[:down, []]])
    expect(d.feed("\e")).to eq([])
    expect(chords(d.flush)).to eq([[:escape, []]])
    expect(d.pending?).to eq(false)
  end

  it 'reads Alt-keys arriving together as one key' do
    ev = d.feed("\ex\e\x7f")
    expect(chords(ev)).to eq([['x', [:alt]], [:backspace, [:alt]]])
    expect(ev[0].bytes).to eq("\ex".b)
  end

  it 'gives a bracketed paste as one event, even split across reads' do
    expect(d.feed("\e[200~line 1\r\nfoo\e[2")).to eq([])
    expect(d.pending?).to eq(true)
    ev = d.feed("01~x")
    expect(ev[0]).to eq(input::Paste.new(text: "line 1\r\nfoo"))
    expect(chords(ev[1..])).to eq([['x', []]])
  end

  it 'decodes SGR mouse reports, focus, and replies' do
    d.expect_cpr = true
    ev = d.feed("\e[<0;10;5M\e[<32;11;5M\e[<0;11;5m\e[<64;1;1M\e[I\e[12;40R\e[?2026;2$y\e[?62;22c\e[?1u")
    expect(ev).to eq([
      input::Mouse.new(button: 0, x: 9, y: 4, action: :press, mods: []),
      input::Mouse.new(button: 0, x: 10, y: 4, action: :drag, mods: []),
      input::Mouse.new(button: 0, x: 10, y: 4, action: :release, mods: []),
      input::Mouse.new(button: 64, x: 0, y: 0, action: :press, mods: []),
      input::Focus.new(in: true),
      input::Reply.new(kind: :cursor, data: [12, 40]),
      input::Reply.new(kind: :mode, data: [2026, 2]),
      input::Reply.new(kind: :device, data: [62, 22]),
      input::Reply.new(kind: :kitty, data: 1),
    ])
  end

  it 'decodes kitty keyboard protocol keys' do
    ev = d.feed("\e[27u\e[97;5u\e[13;2u")
    expect(chords(ev)).to eq([[:escape, []], ['a', [:ctrl]], [:enter, [:shift]]])
  end

  it 'maps keys to actions with keymaps, passing digits from ranges' do
    km = input::Keymap.new(:t) do
      on '1'..'9', :focus_index
      on [:right, :shift], :resize, :right, 5
      on %w[h j], :nop
    end
    expect(km[key.of('3')]).to eq(input::Action.of(:focus_index, 3))
    expect(km[key.of(:right, :shift, bytes: "\e[1;2C")]).to eq(input::Action.of(:resize, :right, 5))
    expect(km[key.of(:right)]).to be_nil
    expect(km.bindings).to include('shift-right' => :resize, 'h' => :nop)
    km.off('h')
    expect(km[key.of('h')]).to be_nil
  end
end
