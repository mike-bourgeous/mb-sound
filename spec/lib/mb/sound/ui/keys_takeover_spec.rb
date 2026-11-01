require_relative '../../../../support/ui_helpers'

# KEYS on the sound-design screen (ux-notes-2, the maintainer's note 6 and
# his "Arm + hold the clip"): entering KEYS with a track inspected arms it
# with its monitor and holds its clip, as console lines; leaving puts back
# what was there (the clip in time, the arm as it was), for tracks with a
# clip, none, a wire, an arm already, or only a graph.
RSpec.describe(MB::Sound::UI::Keyboard::Takeover, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  after do
    @tiles&.stop
    @term&.close
    @session&.close
    ui::Inspect.target = nil
    MB::Sound.rewind
  end

  def new_session
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false, raise_errors: true,
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 120))
    # (a stand-in for live input, so arming opens no MIDI port)
    @session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new)
    @session
  end

  def console(s, *lines)
    b = MB::Sound::Take.console_binding
    lines.each { |code| MB::Sound::Session.with_context(session: s) { b.eval(code) } }
    s.process_buffer
  end

  # A Takeover whose lines run in +s+'s console context (as UI.run_line
  # does for the screen), kept in @lines.
  def takeover(s)
    @lines = []
    described_class.new(run: ->(code, _note) { @lines << code; ui.run_line(code, s) })
  end

  def link_for(s) = ui::Keyboard::Link.new(session: s, patch: nil)

  it 'has a row for every state and event' do
    expect(described_class::TABLE.keys.map(&:first).uniq.sort).to eq(%i[off on])
    expect(described_class::TABLE.keys.map(&:last).uniq.sort).to eq(%i[enter leave])
  end

  it 'arms and holds a playing track, and puts both back when KEYS ends' do
    s = new_session
    console(s, 'track(:bass) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }', 'bg :bass, seq(A2).n4.loop, on: :now')
    t = takeover(s)
    link = link_for(s)
    expect(t.enter(s, :bass, link)).to eq(['arm :bass', 'hold :bass'])
    s.process_buffer
    expect(s.arrangement.armed?(:bass)).to eq(true)
    expect(s.players.keys).to include(:bass, :"bass/live")
    expect(s.held_tracks).to eq([:bass])
    expect(s.audible?(:bass)).to eq(false)
    expect(t.enter(s, :bass, link)).to eq([]) # (already taken over)

    expect(t.leave(link)).to eq(['unhold :bass', 'disarm :bass'])
    s.process_buffer
    expect(s.arrangement.armed?(:bass)).to eq(false)
    expect(s.held_tracks).to eq([])
    expect(s.audible?(:bass)).to eq(true)
    expect(t.leave(link)).to eq([])
    expect(s.journal.changes.map(&:kind)).to include(:arm, :hold, :unhold, :disarm)
  end

  it 'only holds a track armed already, and leaves its arm' do
    s = new_session
    console(s, 'track(:bass) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }', 'bg :bass, seq(A2).n4.loop, on: :now', 'arm :bass')
    t = takeover(s)
    expect(t.enter(s, :bass)).to eq(['hold :bass'])
    expect(t.leave).to eq(['unhold :bass'])
    s.process_buffer
    expect(s.arrangement.armed?(:bass)).to eq(true)
  end

  it 'arms a track without a clip, and puts back a silent arm with its input' do
    s = new_session
    s.midi_in(:keys).input = MB::Sound::MIDI::Stream.new(MIDIListSource.new)
    console(s, 'track(:lead) { |c| c.synth(voices: 2) { |v| v.hz.square * v.amp_env } }', 'arm :lead, monitor: false, input: :keys')
    t = takeover(s)
    link = link_for(s)
    expect(t.enter(s, :lead, link)).to eq(['arm :lead, input: :keys', 'hold :lead'])
    expect(link.input).to eq(:keys) # (the keyboard plays where the monitor listens)
    expect(t.leave(link)).to eq(['unhold :lead', 'arm :lead, monitor: false, input: :keys'])
    expect(link.input).to be_nil
    s.process_buffer
    expect(s.arrangement.arms[:lead].monitoring?).to eq(false)
    expect(s.arrangement.arms[:lead].input).to eq(:keys)
  end

  it 'plays a wired track from its wire input, holding the wire, and gives the input back' do
    s = new_session
    console(s, 'track(:lead) { |c| c.synth(voices: 2) { |v| v.hz.square * v.amp_env } }', 'bg :clock, 0.constant, on: :now', 'wire :lead, seq(C4, E4).n8.loop.stream')
    s.process_buffer
    t = takeover(s)
    link = link_for(s)
    expect(t.enter(s, :lead, link)).to eq(['hold :lead'])
    expect(link.input).to eq(MB::Sound::Session::Name.wire(:lead))
    link.attach
    expect(s.midi_in(MB::Sound::Session::Name.wire(:lead)).sources.length).to eq(2) # (the wire and the keyboard)
    expect(t.leave(link)).to eq(['unhold :lead'])
    expect(s.midi_in(MB::Sound::Session::Name.wire(:lead)).sources.length).to eq(1)
    expect(s.arrangement.arms[:lead].wired?).to eq(true)
  end

  it 'leaves a graph track (nothing to monitor) and an unknown name alone' do
    s = new_session
    console(s, 'bg :pad, 220.hz.saw.at(-30.db), on: :now')
    t = takeover(s)
    expect(t.enter(s, :pad)).to eq([])
    expect(t.on?).to eq(true)
    expect(t.leave).to eq([])
    expect(t.enter(s, :nothing)).to eq([])
  end

  it 'arms and holds the inspected track when the sound screen enters KEYS, quietly, and puts it back on the way out' do
    s = new_session
    console(s, 'track(:bass) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }', 'bg :bass, seq(A2).n4.loop, on: :now')
    ui::Inspect.target = { track: :bass, node: nil }.freeze
    keyboard = ui::Keyboard.new(out: link_for(s), off_mode: :tap)
    @keyboard = keyboard
    @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, keyboard: keyboard, session: s, context: MB::Sound::Take.console_binding)
    expect(@term.wait_for('t> ')).to eq(true), @term.text
    @tiles.keys
    expect(@term.wait_for(' KEYS ')).to eq(true)
    expect(wait_until { s.held_tracks == [:bass] && s.arrangement.armed?(:bass) }).to eq(true), @term.text
    expect(@term.text).not_to match(/hold :bass|arm :bass/) # (no printout: the maintainer, 2026-11-02)
    expect(s.journal.entries.map(&:kind)).to include(:hold)

    @term.write("\x1d") # (Ctrl-]: NAV, out of KEYS)
    expect(@term.wait_for(' NAV ')).to eq(true)
    expect(wait_until { s.held_tracks.empty? && !s.arrangement.armed?(:bass) }).to eq(true), @term.text
    expect(@term.text).not_to match(/unhold :bass|disarm :bass/)
  end
end
